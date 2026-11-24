import Foundation

// MARK: - Raw records produced by the parser

public struct SMSRecord: Sendable {
    public var address: String
    public var date: Int64          // ms since epoch
    public var dateSent: Int64?
    public var type: Int            // 1 received, 2 sent, 3 draft, 4 outbox, 5 failed, 6 queued
    public var body: String?
    public var subject: String?
    public var read: Bool
    public var contactName: String?
}

public struct MMSPart: Sendable {
    public var seq: Int
    public var contentType: String
    public var name: String?
    public var text: String?
    public var data: Data?
}

public struct MMSAddr: Sendable {
    public var address: String
    public var type: Int            // 137 from, 151 to, 130 cc, 129 bcc
}

public struct MMSRecord: Sendable {
    public var address: String?     // "~"-separated participants (excluding the phone owner)
    public var date: Int64
    public var dateSent: Int64?
    public var msgBox: Int          // 1 received, 2 sent, 3 draft, 4 outbox
    public var subject: String?
    public var read: Bool
    public var contactName: String?
    public var messageId: String?
    public var parts: [MMSPart] = []
    public var addrs: [MMSAddr] = []
}

public struct CallRecord: Sendable {
    public var number: String
    public var duration: Int        // seconds
    public var date: Int64
    public var type: Int
    public var contactName: String?
}

public enum BackupRecord: Sendable {
    case sms(SMSRecord)
    case mms(MMSRecord)
    case call(CallRecord)
}

// MARK: - Stored / query models

public enum MessageDirection: Int, Sendable, Codable {
    case incoming = 1
    case outgoing = 2

    public var label: String { self == .incoming ? "incoming" : "outgoing" }
}

public struct Conversation: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let threadKey: String
    public let displayName: String
    public let addresses: [String]
    public let isGroup: Bool
    public let messageCount: Int
    public let lastDate: Date?
    public let lastSnippet: String?
}

public struct Message: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let conversationId: Int64
    public let kind: String               // "sms" | "mms"
    public let date: Date
    public let direction: MessageDirection
    public let box: Int
    public let address: String?
    public let sender: String?            // phone number of sender for incoming messages
    public let senderName: String?        // resolved contact name for sender, if known
    public let contactName: String?       // contact_name attribute from the backup
    public let body: String?
    public let subject: String?
    public let attachmentCount: Int

    /// Best human-readable label for who sent this message.
    public var senderDisplay: String {
        if direction == .outgoing { return "Me" }
        if let senderName, !senderName.isEmpty { return senderName }
        if let sender, !sender.isEmpty { return sender }
        if let contactName, !contactName.isEmpty, contactName != "(Unknown)" { return contactName }
        return address ?? "Unknown"
    }
}

public struct AttachmentInfo: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let messageId: Int64
    public let seq: Int
    public let contentType: String
    public let name: String?
    public let size: Int

    public var isImage: Bool { contentType.lowercased().hasPrefix("image/") }
    public var isVideo: Bool { contentType.lowercased().hasPrefix("video/") }
    public var isAudio: Bool { contentType.lowercased().hasPrefix("audio/") }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public let message: Message
    public let conversationName: String
    public let snippet: String
    public var id: Int64 { message.id }
}

public struct CallEntry: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let number: String
    public let contactName: String?
    public let date: Date
    public let duration: Int
    public let type: Int

    public var typeName: String { CallEntry.typeName(type) }

    public static func typeName(_ t: Int) -> String {
        switch t {
        case 1: return "Incoming"
        case 2: return "Outgoing"
        case 3: return "Missed"
        case 4: return "Voicemail"
        case 5: return "Rejected"
        case 6: return "Blocked"
        case 7: return "Answered Externally"
        default: return "Unknown"
        }
    }

    public static func typeCode(_ name: String) -> Int? {
        switch name.lowercased() {
        case "incoming": return 1
        case "outgoing": return 2
        case "missed": return 3
        case "voicemail": return 4
        case "rejected": return 5
        case "blocked": return 6
        default: return nil
        }
    }
}

public struct SearchQuery: Sendable {
    public var text: String?
    public var conversationId: Int64?
    public var contact: String?
    public var after: Date?
    public var before: Date?
    public var direction: MessageDirection?
    public var hasAttachments: Bool?
    public var limit: Int
    public var offset: Int

    public init(text: String? = nil, conversationId: Int64? = nil, contact: String? = nil,
                after: Date? = nil, before: Date? = nil, direction: MessageDirection? = nil,
                hasAttachments: Bool? = nil, limit: Int = 100, offset: Int = 0) {
        self.text = text
        self.conversationId = conversationId
        self.contact = contact
        self.after = after
        self.before = before
        self.direction = direction
        self.hasAttachments = hasAttachments
        self.limit = limit
        self.offset = offset
    }
}

public struct CallQuery: Sendable {
    public var text: String?
    public var type: Int?
    public var after: Date?
    public var before: Date?
    public var limit: Int
    public var offset: Int

    public init(text: String? = nil, type: Int? = nil, after: Date? = nil, before: Date? = nil,
                limit: Int = 500, offset: Int = 0) {
        self.text = text
        self.type = type
        self.after = after
        self.before = before
        self.limit = limit
        self.offset = offset
    }
}

public struct StoreStats: Sendable {
    public var messages: Int
    public var sms: Int
    public var mms: Int
    public var conversations: Int
    public var calls: Int
    public var attachments: Int
    public var attachmentBytes: Int64
    public var firstMessage: Date?
    public var lastMessage: Date?
    public var topConversations: [Conversation]
}

public struct ImportSource: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let fileName: String
    public let path: String
    public let importedAt: Date
    public let recordsSeen: Int
    public let messagesAdded: Int
    public let callsAdded: Int
}

public struct ImportProgress: Sendable {
    public var fileName: String
    public var bytesRead: Int64
    public var totalBytes: Int64
    public var recordsSeen: Int
    public var messagesAdded: Int
    public var callsAdded: Int
    /// True while a .zip archive is being expanded (no byte progress is available yet).
    public var isExtracting: Bool = false

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(bytesRead) / Double(totalBytes)) : 0
    }
}

public struct ImportResult: Sendable {
    public var fileName: String
    public var recordsSeen: Int
    public var messagesAdded: Int
    public var callsAdded: Int
    public var duplicatesSkipped: Int
}

// MARK: - Helpers

public enum PhoneNumber {
    /// Normalizes an address into a matching key. Phone numbers are reduced to their
    /// last 10 digits (so "+1 (207) 555-0100" and "2075550100" match); emails and
    /// alphanumeric senders are lowercased.
    public static func key(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.contains("@") { return trimmed.lowercased() }
        let digits = trimmed.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }
        let letters = trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        if letters && digits.count < 5 { return trimmed.lowercased() }
        if digits.isEmpty { return trimmed.lowercased() }
        let d = String(String.UnicodeScalarView(digits))
        return d.count > 10 ? String(d.suffix(10)) : d
    }

    public static func isPlaceholder(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.isEmpty || l == "insert-address-token" || l == "null"
    }
}

public enum DateUtil {
    public static func fromMillis(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    public static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    /// Normalizes a timestamp that might be in seconds to milliseconds.
    public static func normalizeMillis(_ v: Int64) -> Int64 {
        (v > 0 && v < 100_000_000_000) ? v * 1000 : v
    }

    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// Parses ISO-8601 dates/datetimes ("2024-03-01", "2024-03-01T14:30", "2024-03-01T14:30:00-05:00")
    /// or epoch milliseconds. Dates without a zone are interpreted in the local time zone.
    public static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if let n = Int64(t) { return fromMillis(normalizeMillis(n)) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        let formats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy-MM", "yyyy"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        for f in formats {
            df.dateFormat = f
            if let d = df.date(from: t) { return d }
        }
        return nil
    }
}

/// 64-bit FNV-1a hash, used for de-duplication keys.
func fnv1a(_ s: String?) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in (s ?? "").utf8 {
        h ^= UInt64(b)
        h = h &* 0x100000001b3
    }
    return String(h, radix: 36)
}
