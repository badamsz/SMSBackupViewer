import Foundation
import SMSBackupCore

// smsbackup-mcp — a local Model Context Protocol server (stdio transport) that exposes the
// SMS Backup Viewer database to MCP clients such as Claude Desktop and Claude Code.
//
// Usage:
//   smsbackup-mcp [--db /path/to/messages.sqlite]          run as an MCP server over stdin/stdout
//   smsbackup-mcp import <file.xml|file.zip>... [--db PATH] import backups from the command line
//   smsbackup-mcp stats [--db PATH]                        print database statistics

let serverVersion = "1.0.0"

func log(_ s: String) {
    FileHandle.standardError.write(Data(("[smsbackup-mcp] " + s + "\n").utf8))
}

// MARK: - Argument parsing

var dbURL = MessageStore.defaultDatabaseURL
var positional: [String] = []
do {
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--db":
            guard !args.isEmpty else { log("--db requires a path"); exit(2) }
            dbURL = URL(fileURLWithPath: (args.removeFirst() as NSString).expandingTildeInPath)
        case "--help", "-h":
            print("""
            smsbackup-mcp \(serverVersion)
              smsbackup-mcp [--db PATH]               Run the MCP server on stdio
              smsbackup-mcp import FILE... [--db PATH] Import SMS Backup & Restore .xml or .zip files
              smsbackup-mcp stats [--db PATH]          Show database statistics
            Default database: \(MessageStore.defaultDatabaseURL.path)
            """)
            exit(0)
        case "--version":
            print(serverVersion); exit(0)
        default:
            positional.append(a)
        }
    }
}

// MARK: - CLI subcommands

if let cmd = positional.first {
    do {
        let store = try MessageStore(url: dbURL)
        switch cmd {
        case "import":
            for path in positional.dropFirst() {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                var lastPct = -1
                var lastName = ""
                let results = try store.importFile(at: url, progress: { p in
                    if p.isExtracting { log("unzipping \(p.fileName)…"); return }
                    if p.fileName != lastName { lastName = p.fileName; lastPct = -1 }
                    let pct = Int(p.fraction * 100)
                    if pct != lastPct, pct % 10 == 0 { lastPct = pct; log("\(p.fileName): \(pct)%") }
                })
                for r in results {
                    print("\(r.fileName): \(r.recordsSeen) records, \(r.messagesAdded) messages added, \(r.callsAdded) calls added, \(r.duplicatesSkipped) duplicates skipped")
                }
            }
        case "stats":
            let s = try store.stats()
            print("Messages: \(s.messages) (SMS \(s.sms), MMS \(s.mms))")
            print("Conversations: \(s.conversations)")
            print("Calls: \(s.calls)")
            print("Attachments: \(s.attachments) (\(ByteCountFormatter.string(fromByteCount: s.attachmentBytes, countStyle: .file)))")
            if let f = s.firstMessage, let l = s.lastMessage { print("Range: \(DateUtil.iso(f)) → \(DateUtil.iso(l))") }
            print("Full-text search: \(store.ftsEnabled ? "FTS5" : "LIKE fallback")")
            print("Database: \(store.url.path)")
        default:
            log("Unknown command \(cmd). Use --help.")
            exit(2)
        }
        exit(0)
    } catch {
        log("Error: \(error.localizedDescription)")
        exit(1)
    }
}

// MARK: - JSON helpers

typealias JSON = [String: Any]

func str(_ args: JSON, _ k: String) -> String? {
    if let s = args[k] as? String { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
    if let n = args[k] as? NSNumber { return n.stringValue }
    return nil
}

func int(_ args: JSON, _ k: String) -> Int? {
    if let n = args[k] as? NSNumber { return n.intValue }
    if let s = args[k] as? String { return Int(s) }
    return nil
}

func bool(_ args: JSON, _ k: String) -> Bool? {
    if let b = args[k] as? Bool { return b }
    if let n = args[k] as? NSNumber { return n.boolValue }
    if let s = args[k] as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
    return nil
}

struct ToolError: Error { let message: String }

func date(_ args: JSON, _ k: String) throws -> Date? {
    guard let s = str(args, k) else { return nil }
    guard let d = DateUtil.parse(s) else {
        throw ToolError(message: "Could not parse \(k)=\"\(s)\". Use ISO 8601 like 2024-03-01 or 2024-03-01T14:30.")
    }
    return d
}

func clampLimit(_ v: Int?, default d: Int, max m: Int) -> Int { Swift.max(1, Swift.min(v ?? d, m)) }

func truncate(_ s: String?, _ n: Int) -> String? {
    guard let s else { return nil }
    return s.count > n ? String(s.prefix(n)) + "… [truncated]" : s
}

func messageJSON(_ m: Message, conversationName: String? = nil, bodyLimit: Int = 4000) -> JSON {
    var o: JSON = [
        "id": m.id,
        "conversation_id": m.conversationId,
        "date": DateUtil.iso(m.date),
        "direction": m.direction.label,
        "from": m.direction == .outgoing ? "me" : m.senderDisplay,
        "type": m.kind,
    ]
    if let conversationName { o["conversation"] = conversationName }
    if m.direction == .incoming, let s = m.sender { o["from_number"] = s }
    if let b = truncate(m.body, bodyLimit) { o["text"] = b }
    if let s = m.subject, !s.isEmpty { o["subject"] = s }
    if m.attachmentCount > 0 { o["attachment_count"] = m.attachmentCount }
    return o
}

func conversationJSON(_ c: Conversation) -> JSON {
    var o: JSON = [
        "id": c.id,
        "name": c.displayName,
        "addresses": c.addresses,
        "is_group": c.isGroup,
        "message_count": c.messageCount,
    ]
    if let d = c.lastDate { o["last_message_date"] = DateUtil.iso(d) }
    if let s = c.lastSnippet { o["last_message"] = truncate(s, 160) }
    return o
}

// MARK: - Tool definitions

let dateHint = "ISO 8601 date or datetime in local time, e.g. 2024-03-01 or 2024-03-01T18:00"

func prop(_ type: String, _ description: String? = nil, oneOf values: [String]? = nil) -> JSON {
    var p: JSON = ["type": type]
    if let description { p["description"] = description }
    if let values { p["enum"] = values }
    return p
}

func tool(_ name: String, _ title: String, _ description: String,
          properties: [String: JSON] = [:], required: [String] = [], readOnly: Bool = true) -> JSON {
    var schema: JSON = ["type": "object", "properties": properties]
    if !required.isEmpty { schema["required"] = required }
    var annotations: JSON = ["readOnlyHint": readOnly, "title": title]
    if !readOnly {
        annotations["destructiveHint"] = false
        annotations["idempotentHint"] = true
    }
    return ["name": name, "title": title, "description": description, "inputSchema": schema, "annotations": annotations]
}

var tools: [JSON] = []

tools.append(tool(
    "search_messages", "Search text messages",
    "Full-text search across all imported SMS/MMS messages. Words match by prefix; wrap phrases in double quotes. All filters are optional and combinable: omit 'query' to list messages matching only the filters (for example everything from a contact in a date range). Results are newest first.",
    properties: [
        "query": prop("string", "Words or \"exact phrases\" to find in message text."),
        "contact": prop("string", "Filter by contact name or phone number (partial match)."),
        "conversation_id": prop("integer", "Restrict to one conversation (id from list_conversations)."),
        "after": prop("string", "Only messages on/after this time. " + dateHint),
        "before": prop("string", "Only messages before this time. " + dateHint),
        "direction": prop("string", "incoming = received, outgoing = sent by the phone owner.", oneOf: ["incoming", "outgoing"]),
        "has_attachments": prop("boolean", "Only messages with (true) or without (false) MMS attachments."),
        "limit": prop("integer", "Max results (default 25, max 200)."),
        "offset": prop("integer", "Skip this many results, for paging."),
    ]))

tools.append(tool(
    "list_conversations", "List conversations",
    "List message threads ordered by most recent activity, optionally filtered by contact name or phone number.",
    properties: [
        "filter": prop("string", "Partial contact name or phone number."),
        "limit": prop("integer", "Max results (default 50, max 500)."),
        "offset": prop("integer", "Skip this many results, for paging."),
    ]))

tools.append(tool(
    "get_conversation", "Read a conversation",
    "Read messages from one conversation in chronological order. By default returns the most recent messages. Use around_message_id to read the context around a search hit, or after/before to page through time.",
    properties: [
        "conversation_id": prop("integer", "Conversation id (required unless around_message_id is given)."),
        "around_message_id": prop("integer", "Return messages surrounding this message id."),
        "after": prop("string", "Return the first messages on/after this time. " + dateHint),
        "before": prop("string", "Return the last messages before this time. " + dateHint),
        "limit": prop("integer", "Max messages (default 100, max 500)."),
    ]))

tools.append(tool(
    "get_message", "Get a message",
    "Get one message in full, including its list of MMS attachments.",
    properties: ["message_id": prop("integer")], required: ["message_id"]))

tools.append(tool(
    "get_attachment", "Get an MMS attachment",
    "Fetch an MMS attachment by id. Images are returned as image content so they can be viewed; text and vCards are returned as text; other types return metadata only.",
    properties: ["attachment_id": prop("integer")], required: ["attachment_id"]))

tools.append(tool(
    "search_calls", "Search call log",
    "Search the imported call log (from calls-*.xml backups), newest first.",
    properties: [
        "contact": prop("string", "Partial contact name or phone number."),
        "type": prop("string", "Call type.", oneOf: ["incoming", "outgoing", "missed", "voicemail", "rejected", "blocked"]),
        "after": prop("string", dateHint),
        "before": prop("string", dateHint),
        "limit": prop("integer", "Max results (default 50, max 500)."),
        "offset": prop("integer", "Skip this many results, for paging."),
    ]))

tools.append(tool(
    "get_stats", "Archive statistics",
    "Overview of the imported archive: message and call counts, date range, most active conversations, and imported files."))

tools.append(tool(
    "import_backup", "Import a backup file",
    "Import an SMS Backup & Restore file from this Mac into the archive: an sms-*.xml or calls-*.xml backup, or a .zip containing them (every .xml inside is imported). Duplicate messages are skipped, so re-importing or importing overlapping backups is safe.",
    properties: ["path": prop("string", "Absolute path to the .xml or .zip file (~ allowed).")],
    required: ["path"], readOnly: false))

// MARK: - Server

final class Server {
    private var storeInstance: MessageStore?

    func openStore() throws -> MessageStore {
        if let s = storeInstance { return s }
        let s = try MessageStore(url: dbURL)
        storeInstance = s
        return s
    }

    func run() {
        log("starting (db: \(dbURL.path))")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = parsed as? [JSON] {
                let responses = batch.compactMap { handle($0) }
                if !responses.isEmpty { sendRaw(responses) }
            } else if let msg = parsed as? JSON, let response = handle(msg) {
                send(response)
            }
        }
        log("stdin closed, exiting")
    }

    private func send(_ obj: JSON) { sendRaw(obj) }

    private func sendRaw(_ obj: Any) {
        do {
            var data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        } catch {
            log("failed to encode response: \(error)")
        }
    }

    /// Returns a response for requests, nil for notifications.
    private func handle(_ msg: JSON) -> JSON? {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]
        let params = msg["params"] as? JSON ?? [:]
        guard let id, !(id is NSNull) else {
            // Notification (e.g. notifications/initialized, notifications/cancelled) — nothing to return.
            return nil
        }
        func ok(_ result: Any) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }
        func err(_ code: Int, _ message: String) -> JSON { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }

        switch method {
        case "initialize":
            let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
            let requested = params["protocolVersion"] as? String ?? ""
            let version = supported.contains(requested) ? requested : "2025-06-18"
            return ok([
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "sms-backup", "title": "SMS Backup Viewer", "version": serverVersion],
                "instructions": "Read-only access to the user's archived Android text messages and call logs imported from SMS Backup & Restore. Use search_messages to find messages, then get_conversation with around_message_id to read context. Dates are in the user's local time zone.",
            ])
        case "ping":
            return ok([String: Any]())
        case "tools/list":
            return ok(["tools": tools])
        case "resources/list":
            return ok(["resources": [Any]()])
        case "resources/templates/list":
            return ok(["resourceTemplates": [Any]()])
        case "prompts/list":
            return ok(["prompts": [Any]()])
        case "tools/call":
            guard let name = params["name"] as? String else { return err(-32602, "Missing tool name") }
            let args = params["arguments"] as? JSON ?? [:]
            do {
                let content = try callTool(name, args)
                return ok(["content": content, "isError": false])
            } catch let e as ToolError {
                return ok(["content": [["type": "text", "text": e.message]], "isError": true])
            } catch {
                return ok(["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true])
            }
        default:
            return err(-32601, "Method not found: \(method)")
        }
    }

    private func textContent(_ obj: Any) -> [JSON] {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data("{}".utf8)
        return [["type": "text", "text": String(decoding: data, as: UTF8.self)]]
    }

    private func callTool(_ name: String, _ args: JSON) throws -> [JSON] {
        let store = try openStore()
        switch name {
        case "search_messages":
            var dir: MessageDirection?
            if let d = str(args, "direction") {
                guard let parsed = ["incoming": MessageDirection.incoming, "outgoing": .outgoing][d.lowercased()] else {
                    throw ToolError(message: "direction must be 'incoming' or 'outgoing'")
                }
                dir = parsed
            }
            let after = try date(args, "after")
            let before = try date(args, "before")
            let q = SearchQuery(text: str(args, "query"),
                                conversationId: int(args, "conversation_id").map { Int64($0) },
                                contact: str(args, "contact"),
                                after: after,
                                before: before,
                                direction: dir,
                                hasAttachments: bool(args, "has_attachments"),
                                limit: clampLimit(int(args, "limit"), default: 25, max: 200),
                                offset: max(0, int(args, "offset") ?? 0))
            let hits = try store.search(q)
            let results: [JSON] = hits.map { h in
                var o = messageJSON(h.message, conversationName: h.conversationName, bodyLimit: 1000)
                if q.text != nil, store.ftsEnabled { o["match"] = h.snippet }
                return o
            }
            var out: JSON = ["count": results.count, "messages": results]
            if results.count == q.limit { out["next_offset"] = q.offset + q.limit }
            if results.isEmpty, (try? store.stats().messages) == 0 {
                out["note"] = "The archive is empty. Import a backup in the SMS Backup Viewer app or with the import_backup tool."
            }
            return textContent(out)

        case "list_conversations":
            let limit = clampLimit(int(args, "limit"), default: 50, max: 500)
            let offset = max(0, int(args, "offset") ?? 0)
            let convs = try store.conversations(filter: str(args, "filter"), limit: limit, offset: offset)
            var out: JSON = ["count": convs.count, "conversations": convs.map(conversationJSON)]
            if convs.count == limit { out["next_offset"] = offset + limit }
            return textContent(out)

        case "get_conversation":
            let limit = clampLimit(int(args, "limit"), default: 100, max: 500)
            var messages: [Message]
            var convId: Int64
            if let around = int(args, "around_message_id") {
                messages = try store.messages(around: Int64(around), before: limit / 2, after: limit / 2)
                guard let first = messages.first else { throw ToolError(message: "No message with id \(around)") }
                convId = first.conversationId
            } else if let cid = int(args, "conversation_id") {
                convId = Int64(cid)
                if let after = try date(args, "after") {
                    messages = try store.messages(conversationId: convId, after: (DateUtil.millis(after), 0), limit: limit)
                } else if let before = try date(args, "before") {
                    messages = try store.messages(conversationId: convId, before: (DateUtil.millis(before), 0), limit: limit)
                } else {
                    messages = try store.messages(conversationId: convId, limit: limit)
                }
            } else {
                throw ToolError(message: "Provide conversation_id or around_message_id.")
            }
            guard let conv = try store.conversation(id: convId) else { throw ToolError(message: "No conversation with id \(convId)") }
            var out: JSON = [
                "conversation": conversationJSON(conv),
                "count": messages.count,
                "messages": messages.map { messageJSON($0) },
            ]
            if let first = messages.first { out["earliest_returned"] = DateUtil.iso(first.date) }
            if let last = messages.last { out["latest_returned"] = DateUtil.iso(last.date) }
            out["hint"] = "Use before=earliest_returned to read further back, or after=latest_returned to read forward."
            return textContent(out)

        case "get_message":
            guard let id = int(args, "message_id") else { throw ToolError(message: "message_id is required") }
            guard let m = try store.message(id: Int64(id)) else { throw ToolError(message: "No message with id \(id)") }
            let conv = try store.conversation(id: m.conversationId)
            var o = messageJSON(m, conversationName: conv?.displayName, bodyLimit: 100_000)
            let atts = try store.attachments(messageId: m.id)
            if !atts.isEmpty {
                o["attachments"] = atts.map { a -> JSON in
                    var j: JSON = ["id": a.id, "content_type": a.contentType, "size_bytes": a.size]
                    if let n = a.name { j["name"] = n }
                    return j
                }
            }
            return textContent(o)

        case "get_attachment":
            guard let id = int(args, "attachment_id") else { throw ToolError(message: "attachment_id is required") }
            guard let att = try store.attachment(id: Int64(id)) else { throw ToolError(message: "No attachment with id \(id)") }
            let (info, data) = att
            var meta: JSON = ["id": info.id, "message_id": info.messageId, "content_type": info.contentType, "size_bytes": info.size]
            if let n = info.name { meta["name"] = n }
            let ct = info.contentType.lowercased()
            if info.isImage, ["image/jpeg", "image/jpg", "image/png", "image/gif", "image/webp"].contains(ct), data.count <= 5_000_000 {
                return [["type": "image", "data": data.base64EncodedString(), "mimeType": ct == "image/jpg" ? "image/jpeg" : ct]] + textContent(meta)
            }
            if ct.hasPrefix("text/") || ct.contains("vcard") || ct.contains("calendar"), let text = String(data: data, encoding: .utf8) {
                meta["text"] = truncate(text, 50_000)
                return textContent(meta)
            }
            meta["note"] = info.isImage
                ? "Image is too large or in an unsupported format (\(ct)) to return inline. Open it in the SMS Backup Viewer app."
                : "Binary attachment (\(ct)); content not returned. Open it in the SMS Backup Viewer app."
            return textContent(meta)

        case "search_calls":
            var type: Int?
            if let t = str(args, "type") {
                guard let code = CallEntry.typeCode(t) else { throw ToolError(message: "Unknown call type \(t)") }
                type = code
            }
            let limit = clampLimit(int(args, "limit"), default: 50, max: 500)
            let offset = max(0, int(args, "offset") ?? 0)
            let after = try date(args, "after")
            let before = try date(args, "before")
            let calls = try store.calls(CallQuery(text: str(args, "contact"), type: type,
                                                  after: after, before: before,
                                                  limit: limit, offset: offset))
            let items: [JSON] = calls.map { c in
                var o: JSON = ["id": c.id, "date": DateUtil.iso(c.date), "number": c.number, "type": c.typeName.lowercased(), "duration_seconds": c.duration]
                if let n = c.contactName { o["contact"] = n }
                return o
            }
            var out: JSON = ["count": items.count, "calls": items]
            if items.count == limit { out["next_offset"] = offset + limit }
            return textContent(out)

        case "get_stats":
            let s = try store.stats()
            let files: [JSON] = try store.sources().prefix(20).map { src -> JSON in
                ["file": src.fileName, "imported_at": DateUtil.iso(src.importedAt), "messages_added": src.messagesAdded, "calls_added": src.callsAdded]
            }
            var out: JSON = [
                "messages": s.messages, "sms": s.sms, "mms": s.mms,
                "conversations": s.conversations, "calls": s.calls,
                "attachments": s.attachments, "attachment_bytes": s.attachmentBytes,
                "full_text_search": store.ftsEnabled,
                "most_active_conversations": s.topConversations.map(conversationJSON),
                "imported_files": files,
                "database": store.url.path,
            ]
            if let f = s.firstMessage { out["first_message_date"] = DateUtil.iso(f) }
            if let l = s.lastMessage { out["last_message_date"] = DateUtil.iso(l) }
            return textContent(out)

        case "import_backup":
            guard let path = str(args, "path") else { throw ToolError(message: "path is required") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError(message: "File not found: \(url.path)") }
            let results = try store.importFile(at: url)
            let files: [JSON] = results.map { r -> JSON in
                [
                    "file": r.fileName, "records_seen": r.recordsSeen,
                    "messages_added": r.messagesAdded, "calls_added": r.callsAdded,
                    "duplicates_skipped": r.duplicatesSkipped,
                ]
            }
            return textContent(["imported": files])

        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }
}

Server().run()
