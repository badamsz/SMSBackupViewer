import Foundation
import SQLite3

/// SQLite-backed index of imported SMS Backup & Restore data. Shared by the app and the MCP server.
public final class MessageStore: @unchecked Sendable {
    public let db: SQLiteDB
    public let url: URL
    public private(set) var ftsEnabled = false

    public static var defaultDatabaseURL: URL {
        if let env = ProcessInfo.processInfo.environment["SMS_BACKUP_DB"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SMSBackupViewer", isDirectory: true).appendingPathComponent("messages.sqlite")
    }

    public init(url: URL = MessageStore.defaultDatabaseURL, readOnly: Bool = false) throws {
        self.url = url
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        db = try SQLiteDB(path: url.path, readOnly: readOnly)
        if readOnly {
            ftsEnabled = (try? db.scalarInt("SELECT 1 FROM sqlite_master WHERE name='messages_fts'")) != nil
        } else {
            try migrate()
        }
    }

    // MARK: Schema

    private func migrate() throws {
        try db.exec("PRAGMA journal_mode=WAL;")
        try db.exec("PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        try db.exec("""
        CREATE TABLE IF NOT EXISTS sources(
            id INTEGER PRIMARY KEY,
            file_name TEXT NOT NULL,
            path TEXT NOT NULL,
            imported_at REAL NOT NULL,
            records_seen INTEGER NOT NULL DEFAULT 0,
            messages_added INTEGER NOT NULL DEFAULT 0,
            calls_added INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS conversations(
            id INTEGER PRIMARY KEY,
            thread_key TEXT NOT NULL UNIQUE,
            display_name TEXT,
            addresses TEXT NOT NULL,
            is_group INTEGER NOT NULL DEFAULT 0,
            message_count INTEGER NOT NULL DEFAULT 0,
            last_date INTEGER,
            last_snippet TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_conversations_last ON conversations(last_date);
        CREATE TABLE IF NOT EXISTS messages(
            id INTEGER PRIMARY KEY,
            conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            date INTEGER NOT NULL,
            date_sent INTEGER,
            direction INTEGER NOT NULL,
            box INTEGER,
            address TEXT,
            sender TEXT,
            sender_key TEXT,
            contact_name TEXT,
            body TEXT,
            subject TEXT,
            read INTEGER,
            attachment_count INTEGER NOT NULL DEFAULT 0,
            source_id INTEGER,
            dedup_key TEXT NOT NULL UNIQUE
        );
        CREATE INDEX IF NOT EXISTS idx_messages_conv_date ON messages(conversation_id, date, id);
        CREATE INDEX IF NOT EXISTS idx_messages_date ON messages(date);
        CREATE TABLE IF NOT EXISTS attachments(
            id INTEGER PRIMARY KEY,
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            seq INTEGER,
            content_type TEXT NOT NULL,
            name TEXT,
            size INTEGER NOT NULL DEFAULT 0,
            data BLOB
        );
        CREATE INDEX IF NOT EXISTS idx_attachments_message ON attachments(message_id);
        CREATE TABLE IF NOT EXISTS calls(
            id INTEGER PRIMARY KEY,
            number TEXT,
            number_key TEXT,
            contact_name TEXT,
            date INTEGER NOT NULL,
            duration INTEGER,
            type INTEGER,
            source_id INTEGER,
            dedup_key TEXT NOT NULL UNIQUE
        );
        CREATE INDEX IF NOT EXISTS idx_calls_date ON calls(date);
        CREATE INDEX IF NOT EXISTS idx_calls_key ON calls(number_key);
        CREATE TABLE IF NOT EXISTS contacts(
            address_key TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            address TEXT,
            updated INTEGER NOT NULL DEFAULT 0
        );
        PRAGMA user_version = 1;
        """)
        do {
            try db.exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                body, content='messages', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
            );
            """)
            ftsEnabled = true
        } catch {
            ftsEnabled = false   // fall back to LIKE searches
        }
    }

    // MARK: Import

    public func importBackup(at url: URL,
                             displayName: String? = nil,
                             sourcePath: String? = nil,
                             progress: ((ImportProgress) -> Void)? = nil,
                             isCancelled: (() -> Bool)? = nil) throws -> ImportResult {
        let parser = BackupParser(url: url)
        let fileName = displayName ?? url.lastPathComponent
        var prog = ImportProgress(fileName: fileName, bytesRead: 0, totalBytes: 0, recordsSeen: 0, messagesAdded: 0, callsAdded: 0)
        var duplicates = 0

        try db.exec("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.exec("ROLLBACK") } }

        try db.prepare("INSERT INTO sources(file_name, path, imported_at) VALUES(?,?,?)")
            .run([fileName, sourcePath ?? url.path, Date().timeIntervalSince1970])
        let sourceId = db.lastInsertRowID

        let selConv = try db.prepare("SELECT id, display_name IS NOT NULL FROM conversations WHERE thread_key = ?")
        let insConv = try db.prepare("INSERT INTO conversations(thread_key, display_name, addresses, is_group) VALUES(?,?,?,?)")
        let updConvName = try db.prepare("UPDATE conversations SET display_name = ? WHERE id = ?")
        let insMsg = try db.prepare("""
            INSERT OR IGNORE INTO messages(conversation_id, kind, date, date_sent, direction, box, address, sender, sender_key,
                contact_name, body, subject, read, attachment_count, source_id, dedup_key)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        let insFTS: Statement? = try ftsEnabled ? db.prepare("INSERT INTO messages_fts(rowid, body) VALUES(?, ?)") : nil
        let insAtt = try db.prepare("INSERT INTO attachments(message_id, seq, content_type, name, size, data) VALUES(?,?,?,?,?,?)")
        let insCall = try db.prepare("""
            INSERT OR IGNORE INTO calls(number, number_key, contact_name, date, duration, type, source_id, dedup_key)
            VALUES(?,?,?,?,?,?,?,?)
            """)
        let upContact = try db.prepare("""
            INSERT INTO contacts(address_key, name, address, updated) VALUES(?,?,?,?)
            ON CONFLICT(address_key) DO UPDATE SET name = excluded.name, address = excluded.address, updated = excluded.updated
            WHERE excluded.updated >= contacts.updated
            """)

        var convCache: [String: (id: Int64, named: Bool)] = [:]
        var touched = Set<Int64>()

        func validName(_ n: String?) -> String? {
            guard let n = n?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, n != "(Unknown)" else { return nil }
            return n
        }

        func conversationId(addresses rawAddresses: [String], name: String?) throws -> (Int64, String) {
            var seen = Set<String>()
            var addrs: [String] = []
            var keys: [String] = []
            for a in rawAddresses {
                let t = a.trimmingCharacters(in: .whitespaces)
                if PhoneNumber.isPlaceholder(t) { continue }
                let k = PhoneNumber.key(t)
                if k.isEmpty || seen.contains(k) { continue }
                seen.insert(k)
                addrs.append(t)
                keys.append(k)
            }
            if keys.isEmpty { keys = ["unknown"]; addrs = ["Unknown"] }
            let threadKey = keys.sorted().joined(separator: "|")
            if let cached = convCache[threadKey] {
                if !cached.named, let name {
                    try updConvName.run([name, cached.id])
                    convCache[threadKey] = (cached.id, true)
                }
                return (cached.id, threadKey)
            }
            try selConv.bind([threadKey])
            if try selConv.step() {
                let id = selConv.int64(0)
                var named = selConv.int(1) == 1
                if !named, let name {
                    try updConvName.run([name, id])
                    named = true
                }
                convCache[threadKey] = (id, named)
                return (id, threadKey)
            }
            try insConv.run([threadKey, name, addrs.joined(separator: ", "), keys.count > 1])
            let id = db.lastInsertRowID
            convCache[threadKey] = (id, name != nil)
            return (id, threadKey)
        }

        func rememberContact(_ address: String, _ name: String?, _ date: Int64) throws {
            guard let name = validName(name), !name.contains(","), !PhoneNumber.isPlaceholder(address) else { return }
            let key = PhoneNumber.key(address)
            guard !key.isEmpty else { return }
            try upContact.run([key, name, address, date])
        }

        func insertMessage(conversation: Int64, kind: String, date: Int64, dateSent: Int64?, direction: MessageDirection,
                           box: Int, address: String?, sender: String?, contactName: String?, body: String?,
                           subject: String?, read: Bool, attachments: [MMSPart], dedup: String) throws {
            let senderKey = sender.map(PhoneNumber.key)
            try insMsg.run([conversation, kind, date, dateSent, direction.rawValue, box, address, sender, senderKey,
                            contactName, body, subject, read, attachments.count, sourceId, dedup])
            guard db.changes == 1 else { duplicates += 1; return }
            let rowId = db.lastInsertRowID
            if let insFTS, let body, !body.isEmpty { try insFTS.run([rowId, body]) }
            for part in attachments {
                let data = part.data ?? Data()
                try insAtt.run([rowId, part.seq, part.contentType, part.name, data.count, data])
            }
            touched.insert(conversation)
            prog.messagesAdded += 1
        }

        try parser.parse(progress: { read, total in
            prog.bytesRead = read
            prog.totalBytes = total
            progress?(prog)
        }) { record in
            prog.recordsSeen += 1
            if prog.recordsSeen % 256 == 0, isCancelled?() == true { throw CancellationError() }

            switch record {
            case .sms(let s):
                let name = validName(s.contactName)
                let (convId, threadKey) = try conversationId(addresses: [s.address], name: name)
                try rememberContact(s.address, s.contactName, s.date)
                let direction: MessageDirection = s.type == 1 ? .incoming : .outgoing
                let dedup = "s|\(s.date)|\(threadKey)|\(s.type)|\(fnv1a(s.body))"
                try insertMessage(conversation: convId, kind: "sms", date: s.date, dateSent: s.dateSent,
                                  direction: direction, box: s.type, address: s.address,
                                  sender: direction == .incoming ? s.address : nil, contactName: s.contactName,
                                  body: s.body, subject: s.subject, read: s.read, attachments: [], dedup: dedup)

            case .mms(let m):
                let direction: MessageDirection = m.msgBox == 1 ? .incoming : .outgoing
                var participants: [String] = []
                if let a = m.address { participants = a.split(separator: "~").map(String.init) }
                if participants.allSatisfy({ PhoneNumber.isPlaceholder($0) }) {
                    participants = m.addrs.filter { direction == .incoming ? $0.type == 137 : $0.type != 137 }.map(\.address)
                }
                let realParticipants = participants.filter { !PhoneNumber.isPlaceholder($0) }
                let name = validName(m.contactName)
                let (convId, threadKey) = try conversationId(addresses: participants, name: name)
                if realParticipants.count == 1 { try rememberContact(realParticipants[0], m.contactName, m.date) }

                var sender: String?
                if direction == .incoming {
                    sender = m.addrs.first(where: { $0.type == 137 && !PhoneNumber.isPlaceholder($0.address) })?.address
                    if sender == nil, realParticipants.count == 1 { sender = realParticipants[0] }
                }

                var texts: [String] = []
                var attachments: [MMSPart] = []
                for part in m.parts.sorted(by: { $0.seq < $1.seq }) {
                    if part.contentType.hasPrefix("text/plain") {
                        if let t = part.text { texts.append(t) }
                        else if let d = part.data, let t = String(data: d, encoding: .utf8) { texts.append(t) }
                    } else if part.data != nil {
                        attachments.append(part)
                    }
                }
                let body = texts.isEmpty ? nil : texts.joined(separator: "\n")
                let idPart = m.messageId ?? "\(fnv1a(body))-\(attachments.count)"
                let dedup = "m|\(m.date)|\(threadKey)|\(m.msgBox)|\(idPart)"
                try insertMessage(conversation: convId, kind: "mms", date: m.date, dateSent: m.dateSent,
                                  direction: direction, box: m.msgBox, address: m.address, sender: sender,
                                  contactName: m.contactName, body: body, subject: m.subject, read: m.read,
                                  attachments: attachments, dedup: dedup)

            case .call(let c):
                let key = PhoneNumber.key(c.number)
                try rememberContact(c.number, c.contactName, c.date)
                let dedup = "c|\(c.date)|\(key)|\(c.duration)|\(c.type)"
                try insCall.run([c.number, key, validName(c.contactName), c.date, c.duration, c.type, sourceId, dedup])
                if db.changes == 1 { prog.callsAdded += 1 } else { duplicates += 1 }
            }
        }

        if parser.kind == .unknown && prog.recordsSeen == 0 {
            throw BackupParseError(message: "\(fileName) doesn't look like an SMS Backup & Restore file (no <smses> or <calls> root).")
        }

        let refresh = try db.prepare("""
            UPDATE conversations SET
              message_count = (SELECT COUNT(*) FROM messages WHERE conversation_id = ?1),
              last_date = (SELECT MAX(date) FROM messages WHERE conversation_id = ?1),
              last_snippet = (SELECT CASE WHEN body IS NOT NULL AND body != '' THEN substr(body, 1, 200)
                                          WHEN attachment_count > 0 THEN '📎 Attachment' ELSE '' END
                              FROM messages WHERE conversation_id = ?1 ORDER BY date DESC, id DESC LIMIT 1)
            WHERE id = ?1
            """)
        for id in touched { try refresh.run([id]) }

        try db.prepare("UPDATE sources SET records_seen = ?, messages_added = ?, calls_added = ? WHERE id = ?")
            .run([prog.recordsSeen, prog.messagesAdded, prog.callsAdded, sourceId])
        try db.exec("COMMIT")
        committed = true
        progress?(prog)

        return ImportResult(fileName: fileName, recordsSeen: prog.recordsSeen, messagesAdded: prog.messagesAdded,
                            callsAdded: prog.callsAdded, duplicatesSkipped: duplicates)
    }

    public func deleteAllData() throws {
        try db.exec("BEGIN")
        do {
            try db.exec("DELETE FROM attachments; DELETE FROM messages; DELETE FROM conversations; DELETE FROM calls; DELETE FROM contacts; DELETE FROM sources;")
            if ftsEnabled { try db.exec("INSERT INTO messages_fts(messages_fts) VALUES('delete-all');") }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        try? db.exec("VACUUM")
    }

    // MARK: Row mapping

    static let messageColumns = """
        m.id, m.conversation_id, m.kind, m.date, m.direction, m.box, m.address, m.sender, ct.name,
        m.contact_name, m.body, m.subject, m.attachment_count
        """
    static let messageFrom = "messages m LEFT JOIN contacts ct ON ct.address_key = m.sender_key"

    static func message(_ st: Statement, _ o: Int32 = 0) -> Message {
        Message(id: st.int64(o),
                conversationId: st.int64(o + 1),
                kind: st.string(o + 2) ?? "sms",
                date: DateUtil.fromMillis(st.int64(o + 3)),
                direction: MessageDirection(rawValue: st.int(o + 4)) ?? .incoming,
                box: st.int(o + 5),
                address: st.string(o + 6),
                sender: st.string(o + 7),
                senderName: st.string(o + 8),
                contactName: st.string(o + 9),
                body: st.string(o + 10),
                subject: st.string(o + 11),
                attachmentCount: st.int(o + 12))
    }

    static let conversationColumns = "c.id, c.thread_key, COALESCE(c.display_name, c.addresses), c.addresses, c.is_group, c.message_count, c.last_date, c.last_snippet"

    static func conversation(_ st: Statement, _ o: Int32 = 0) -> Conversation {
        Conversation(id: st.int64(o),
                     threadKey: st.string(o + 1) ?? "",
                     displayName: st.string(o + 2) ?? "Unknown",
                     addresses: (st.string(o + 3) ?? "").components(separatedBy: ", ").filter { !$0.isEmpty },
                     isGroup: st.int(o + 4) == 1,
                     messageCount: st.int(o + 5),
                     lastDate: st.optInt64(o + 6).map(DateUtil.fromMillis),
                     lastSnippet: st.string(o + 7))
    }

    // MARK: Conversations

    public func conversations(filter: String? = nil, limit: Int = 10_000, offset: Int = 0) throws -> [Conversation] {
        var sql = "SELECT \(Self.conversationColumns) FROM conversations c WHERE c.message_count > 0"
        var params: [SQLBindable?] = []
        if let f = filter?.trimmingCharacters(in: .whitespaces), !f.isEmpty {
            let digits = f.filter(\.isNumber)
            if digits.count >= 3 {
                sql += " AND (c.display_name LIKE ? OR c.addresses LIKE ? OR c.thread_key LIKE ?)"
                params += ["%\(f)%", "%\(f)%", "%\(digits)%"]
            } else {
                sql += " AND (c.display_name LIKE ? OR c.addresses LIKE ?)"
                params += ["%\(f)%", "%\(f)%"]
            }
        }
        sql += " ORDER BY c.last_date DESC LIMIT ? OFFSET ?"
        params += [limit, offset]
        return try db.query(sql, params) { Self.conversation($0) }
    }

    public func conversation(id: Int64) throws -> Conversation? {
        try db.query("SELECT \(Self.conversationColumns) FROM conversations c WHERE c.id = ?", [id]) { Self.conversation($0) }.first
    }

    // MARK: Messages

    /// Most recent messages (or messages before a cursor), returned in chronological order.
    public func messages(conversationId: Int64, before cursor: (date: Int64, id: Int64)? = nil, limit: Int = 200) throws -> [Message] {
        var sql = "SELECT \(Self.messageColumns) FROM \(Self.messageFrom) WHERE m.conversation_id = ?"
        var params: [SQLBindable?] = [conversationId]
        if let c = cursor {
            sql += " AND (m.date < ? OR (m.date = ? AND m.id < ?))"
            params += [c.date, c.date, c.id]
        }
        sql += " ORDER BY m.date DESC, m.id DESC LIMIT ?"
        params.append(limit)
        return try db.query(sql, params) { Self.message($0) }.reversed()
    }

    /// Messages after a cursor, in chronological order.
    public func messages(conversationId: Int64, after cursor: (date: Int64, id: Int64), limit: Int = 200) throws -> [Message] {
        let sql = """
            SELECT \(Self.messageColumns) FROM \(Self.messageFrom)
            WHERE m.conversation_id = ? AND (m.date > ? OR (m.date = ? AND m.id > ?))
            ORDER BY m.date ASC, m.id ASC LIMIT ?
            """
        return try db.query(sql, [conversationId, cursor.date, cursor.date, cursor.id, limit]) { Self.message($0) }
    }

    /// A window of messages centered on `messageId`.
    public func messages(around messageId: Int64, before: Int = 100, after: Int = 100) throws -> [Message] {
        guard let anchor = try message(id: messageId) else { return [] }
        let cursor = (date: DateUtil.millis(anchor.date), id: anchor.id)
        let earlier = try messages(conversationId: anchor.conversationId, before: cursor, limit: before)
        let later = try messages(conversationId: anchor.conversationId, after: cursor, limit: after)
        return earlier + [anchor] + later
    }

    public func message(id: Int64) throws -> Message? {
        try db.query("SELECT \(Self.messageColumns) FROM \(Self.messageFrom) WHERE m.id = ?", [id]) { Self.message($0) }.first
    }

    // MARK: Search

    /// Converts free text into a safe FTS5 query: words become prefix terms, "quoted phrases" stay phrases.
    public static func ftsQuery(_ text: String) -> String? {
        var terms: [String] = []
        var current = ""
        var inQuote = false
        func flush(_ phrase: Bool) {
            let t = current.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            if !t.isEmpty { terms.append(phrase ? "\"\(t)\"" : "\"\(t)\"*") }
            current = ""
        }
        for ch in text {
            if ch == "\"" {
                flush(inQuote)
                inQuote.toggle()
            } else if ch.isWhitespace && !inQuote {
                flush(false)
            } else {
                current.append(ch)
            }
        }
        flush(inQuote)
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    /// Plain search terms (for highlighting).
    public static func searchTerms(_ text: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var inQuote = false
        for ch in text {
            if ch == "\"" { if !current.isEmpty { terms.append(current) }; current = ""; inQuote.toggle() }
            else if ch.isWhitespace && !inQuote { if !current.isEmpty { terms.append(current) }; current = "" }
            else { current.append(ch) }
        }
        if !current.isEmpty { terms.append(current) }
        return terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func search(_ q: SearchQuery) throws -> [SearchHit] {
        var conditions: [String] = []
        var params: [SQLBindable?] = []
        var from = "\(Self.messageFrom) JOIN conversations c ON c.id = m.conversation_id"
        var snippetExpr = "substr(COALESCE(m.body, ''), 1, 240)"
        let order = "m.date DESC, m.id DESC"

        if let text = q.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            if ftsEnabled, let fts = Self.ftsQuery(text) {
                from = "messages_fts JOIN messages m ON m.id = messages_fts.rowid LEFT JOIN contacts ct ON ct.address_key = m.sender_key JOIN conversations c ON c.id = m.conversation_id"
                conditions.append("messages_fts MATCH ?")
                params.append(fts)
                snippetExpr = "snippet(messages_fts, 0, '«', '»', '…', 20)"
            } else {
                for term in Self.searchTerms(text) {
                    conditions.append("m.body LIKE ?")
                    params.append("%\(term)%")
                }
            }
        }
        if let cid = q.conversationId {
            conditions.append("m.conversation_id = ?")
            params.append(cid)
        }
        if let contact = q.contact?.trimmingCharacters(in: .whitespaces), !contact.isEmpty {
            let digits = contact.filter(\.isNumber)
            if digits.count >= 3 {
                conditions.append("(c.display_name LIKE ? OR c.addresses LIKE ? OR c.thread_key LIKE ? OR ct.name LIKE ?)")
                params += ["%\(contact)%", "%\(contact)%", "%\(digits)%", "%\(contact)%"]
            } else {
                conditions.append("(c.display_name LIKE ? OR c.addresses LIKE ? OR ct.name LIKE ?)")
                params += ["%\(contact)%", "%\(contact)%", "%\(contact)%"]
            }
        }
        if let after = q.after {
            conditions.append("m.date >= ?")
            params.append(DateUtil.millis(after))
        }
        if let before = q.before {
            conditions.append("m.date < ?")
            params.append(DateUtil.millis(before))
        }
        if let dir = q.direction {
            conditions.append("m.direction = ?")
            params.append(dir.rawValue)
        }
        if let att = q.hasAttachments {
            conditions.append(att ? "m.attachment_count > 0" : "m.attachment_count = 0")
        }

        var sql = "SELECT \(Self.messageColumns), COALESCE(c.display_name, c.addresses), \(snippetExpr) FROM \(from)"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY \(order) LIMIT ? OFFSET ?"
        params += [q.limit, q.offset]

        return try db.query(sql, params) { st in
            SearchHit(message: Self.message(st), conversationName: st.string(13) ?? "", snippet: st.string(14) ?? "")
        }
    }

    // MARK: Attachments

    public func attachments(messageId: Int64) throws -> [AttachmentInfo] {
        try db.query("SELECT id, message_id, seq, content_type, name, size FROM attachments WHERE message_id = ? ORDER BY seq, id", [messageId]) { st in
            AttachmentInfo(id: st.int64(0), messageId: st.int64(1), seq: st.int(2), contentType: st.string(3) ?? "application/octet-stream",
                           name: st.string(4), size: st.int(5))
        }
    }

    public func attachment(id: Int64) throws -> (info: AttachmentInfo, data: Data)? {
        try db.query("SELECT id, message_id, seq, content_type, name, size, data FROM attachments WHERE id = ?", [id]) { st -> (info: AttachmentInfo, data: Data) in
            (AttachmentInfo(id: st.int64(0), messageId: st.int64(1), seq: st.int(2), contentType: st.string(3) ?? "application/octet-stream",
                            name: st.string(4), size: st.int(5)),
             st.data(6) ?? Data())
        }.first
    }

    // MARK: Calls

    public func calls(_ q: CallQuery = CallQuery()) throws -> [CallEntry] {
        var conditions: [String] = []
        var params: [SQLBindable?] = []
        if let t = q.text?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
            let digits = t.filter(\.isNumber)
            if digits.count >= 3 {
                conditions.append("(contact_name LIKE ? OR number LIKE ? OR number_key LIKE ?)")
                params += ["%\(t)%", "%\(t)%", "%\(digits)%"]
            } else {
                conditions.append("(contact_name LIKE ? OR number LIKE ?)")
                params += ["%\(t)%", "%\(t)%"]
            }
        }
        if let type = q.type { conditions.append("type = ?"); params.append(type) }
        if let a = q.after { conditions.append("date >= ?"); params.append(DateUtil.millis(a)) }
        if let b = q.before { conditions.append("date < ?"); params.append(DateUtil.millis(b)) }
        var sql = "SELECT id, number, contact_name, date, duration, type FROM calls"
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        sql += " ORDER BY date DESC LIMIT ? OFFSET ?"
        params += [q.limit, q.offset]
        return try db.query(sql, params) { st in
            CallEntry(id: st.int64(0), number: st.string(1) ?? "", contactName: st.string(2),
                      date: DateUtil.fromMillis(st.int64(3)), duration: st.int(4), type: st.int(5))
        }
    }

    // MARK: Stats & sources

    public func stats() throws -> StoreStats {
        func count(_ sql: String) -> Int { Int((try? db.scalarInt(sql)) ?? 0) }
        let first = (try? db.scalarInt("SELECT MIN(date) FROM messages")).flatMap { $0 }
        let last = (try? db.scalarInt("SELECT MAX(date) FROM messages")).flatMap { $0 }
        let top = try db.query("SELECT \(Self.conversationColumns) FROM conversations c ORDER BY c.message_count DESC LIMIT 10") { Self.conversation($0) }
        return StoreStats(
            messages: count("SELECT COUNT(*) FROM messages"),
            sms: count("SELECT COUNT(*) FROM messages WHERE kind = 'sms'"),
            mms: count("SELECT COUNT(*) FROM messages WHERE kind = 'mms'"),
            conversations: count("SELECT COUNT(*) FROM conversations WHERE message_count > 0"),
            calls: count("SELECT COUNT(*) FROM calls"),
            attachments: count("SELECT COUNT(*) FROM attachments"),
            attachmentBytes: (try? db.scalarInt("SELECT COALESCE(SUM(size), 0) FROM attachments")).flatMap { $0 } ?? 0,
            firstMessage: first.map(DateUtil.fromMillis),
            lastMessage: last.map(DateUtil.fromMillis),
            topConversations: top)
    }

    public func sources() throws -> [ImportSource] {
        try db.query("SELECT id, file_name, path, imported_at, records_seen, messages_added, calls_added FROM sources ORDER BY imported_at DESC") { st in
            ImportSource(id: st.int64(0), fileName: st.string(1) ?? "", path: st.string(2) ?? "",
                         importedAt: Date(timeIntervalSince1970: st.double(3)), recordsSeen: st.int(4),
                         messagesAdded: st.int(5), callsAdded: st.int(6))
        }
    }

    /// Size of the database files on disk (main + WAL).
    public var fileSize: Int64 {
        let fm = FileManager.default
        return [url.path, url.path + "-wal"].reduce(Int64(0)) { sum, p in
            sum + (((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
