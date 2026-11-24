import Foundation

public struct BackupParseError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// A forgiving, streaming parser for SMS Backup & Restore XML files (sms-*.xml and calls-*.xml).
///
/// Why not XMLParser? Real-world backups routinely contain things a strict XML parser rejects:
///  * emoji written as UTF-16 surrogate-pair character references (`&#55357;&#56832;`)
///  * control characters (`&#1;`, raw 0x0B, …)
///  * multi-megabyte base64 `data` attributes for MMS photos/videos (over libxml2's default limit)
/// This parser reads the file in chunks, handles all of the above, and never loads the whole file.
public final class BackupParser {
    public enum FileKind: String, Sendable { case messages, calls, unknown }

    public private(set) var kind: FileKind = .unknown
    public let url: URL
    private let chunkSize: Int

    public init(url: URL, chunkSize: Int = 4 << 20) {
        self.url = url
        self.chunkSize = chunkSize
    }

    public func parse(progress: ((_ bytesRead: Int64, _ total: Int64) -> Void)? = nil,
                      onRecord: (BackupRecord) throws -> Void) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw BackupParseError(message: "Cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        let total = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0

        let reader = ChunkReader(handle: handle, chunkSize: chunkSize)
        var currentMMS: MMSRecord?
        var lastReported: Int64 = -1
        var attrNames: [(Int, Int)] = []
        var attrValues: [(Int, Int)] = []
        attrNames.reserveCapacity(64)
        attrValues.reserveCapacity(64)

        while let tag = try reader.nextTag() {
            defer { reader.consumeTag() }
            if tag.kind == .other { continue }

            var pending: BackupRecord?
            reader.buf.withUnsafeBufferPointer { p in
                // Element name
                var i = tag.start
                while i < tag.end, !isSpace(p[i]), p[i] != 0x2F { i += 1 }
                let name = String(decoding: UnsafeBufferPointer(rebasing: p[tag.start..<i]), as: UTF8.self)

                if tag.kind == .end {
                    if name == "mms", let mms = currentMMS {
                        pending = .mms(mms)
                        currentMMS = nil
                    }
                    return
                }

                parseAttributes(p, from: i, to: tag.end, names: &attrNames, values: &attrValues)
                let a = Attrs(p: p, names: attrNames, values: attrValues)

                switch name {
                case "smses":
                    kind = .messages
                case "calls":
                    kind = .calls
                case "sms":
                    pending = .sms(SMSRecord(
                        address: a.string("address") ?? "",
                        date: DateUtil.normalizeMillis(a.int64("date") ?? 0),
                        dateSent: a.int64("date_sent").map(DateUtil.normalizeMillis),
                        type: a.int("type") ?? 1,
                        body: a.rawString("body"),
                        subject: a.string("subject"),
                        read: a.int("read") == 1,
                        contactName: a.string("contact_name")))
                case "mms":
                    let rec = MMSRecord(
                        address: a.string("address"),
                        date: DateUtil.normalizeMillis(a.int64("date") ?? 0),
                        dateSent: a.int64("date_sent").map(DateUtil.normalizeMillis),
                        msgBox: a.int("msg_box") ?? 1,
                        subject: a.string("sub"),
                        read: a.int("read") == 1,
                        contactName: a.string("contact_name"),
                        messageId: a.string("m_id"))
                    if tag.selfClosing { pending = .mms(rec) } else { currentMMS = rec }
                case "part":
                    guard currentMMS != nil else { break }
                    let ct = (a.string("ct") ?? "application/octet-stream").lowercased()
                    if ct == "application/smil" { break }
                    var partName = a.string("name")
                    if partName == nil { partName = a.string("fn") }
                    if partName == nil { partName = a.string("cl") }
                    currentMMS?.parts.append(MMSPart(
                        seq: a.int("seq") ?? 0,
                        contentType: ct,
                        name: partName,
                        text: a.string("text"),
                        data: a.base64("data")))
                case "addr":
                    guard currentMMS != nil, let addr = a.string("address") else { break }
                    currentMMS?.addrs.append(MMSAddr(address: addr, type: a.int("type") ?? 0))
                case "call":
                    pending = .call(CallRecord(
                        number: a.string("number") ?? "",
                        duration: a.int("duration") ?? 0,
                        date: DateUtil.normalizeMillis(a.int64("date") ?? 0),
                        type: a.int("type") ?? 0,
                        contactName: a.string("contact_name")))
                default:
                    break
                }
            }

            if let rec = pending {
                try onRecord(rec)
            }
            if let progress, reader.bytesRead - lastReported >= 1 << 20 {
                lastReported = reader.bytesRead
                progress(reader.bytesRead, total)
            }
        }
        if let mms = currentMMS { try onRecord(.mms(mms)) }   // tolerate truncated files
        progress?(reader.bytesRead, total)
    }
}

// MARK: - Tag reader

enum TagKind { case start, end, other }

struct RawTag {
    var kind: TagKind
    var start: Int        // first byte of the element name
    var end: Int          // exclusive; excludes a trailing "/" on self-closing tags
    var selfClosing: Bool
}

final class ChunkReader {
    let handle: FileHandle
    let chunkSize: Int
    var buf: [UInt8] = []
    var pos = 0
    var tagEnd = 0          // index of '>' for the tag most recently returned
    var eof = false
    var bytesRead: Int64 = 0

    init(handle: FileHandle, chunkSize: Int) {
        self.handle = handle
        self.chunkSize = chunkSize
    }

    /// Drops bytes before `pos` and appends the next chunk. Indices relative to `pos` stay valid.
    @discardableResult
    func fill() -> Bool {
        if eof { return false }
        if pos > 0 {
            buf.removeSubrange(0..<pos)
            pos = 0
        }
        let chunk: Data
        do { chunk = try handle.read(upToCount: chunkSize) ?? Data() } catch { chunk = Data() }
        if chunk.isEmpty { eof = true; return false }
        buf.append(contentsOf: chunk)
        bytesRead += Int64(chunk.count)
        return true
    }

    func consumeTag() { pos = tagEnd + 1 }

    private func find(_ byte: UInt8, from: Int) -> Int? {
        guard from < buf.count else { return nil }
        return buf.withUnsafeBufferPointer { p -> Int? in
            guard let base = p.baseAddress else { return nil }
            guard let r = memchr(base + from, Int32(byte), p.count - from) else { return nil }
            return UnsafeRawPointer(base).distance(to: UnsafeRawPointer(r))
        }
    }

    private func hasPrefix(_ s: StaticString, at i: Int) -> Bool {
        let n = s.utf8CodeUnitCount
        guard i + n <= buf.count else { return false }
        let sp = s.utf8Start
        for k in 0..<n where buf[i + k] != sp[k] { return false }
        return true
    }

    private func ensure(_ count: Int) {
        while buf.count - pos < count, fill() {}
    }

    func nextTag() throws -> RawTag? {
        while true {
            // 1. Find the next '<'
            while true {
                if let lt = find(0x3C, from: pos) { pos = lt; break }
                pos = buf.count
                if !fill() { return nil }
            }
            ensure(9)

            // 2. Comments: skip to "-->"
            if hasPrefix("<!--", at: pos) {
                var rel = 4
                while true {
                    if let dash = find(0x2D, from: pos + rel) {
                        if dash + 2 < buf.count {
                            if buf[dash + 1] == 0x2D && buf[dash + 2] == 0x3E {
                                tagEnd = dash + 2
                                break
                            }
                            rel = dash - pos + 1
                            continue
                        }
                        rel = dash - pos
                    } else {
                        rel = buf.count - pos
                    }
                    if !fill() { return nil }
                }
                consumeTag()
                continue
            }

            // 2b. CDATA (not used by SMS Backup & Restore, but skip safely)
            if hasPrefix("<![CDATA[", at: pos) {
                var rel = 9
                while true {
                    if let br = find(0x5D, from: pos + rel), br + 2 < buf.count {
                        if buf[br + 1] == 0x5D && buf[br + 2] == 0x3E { tagEnd = br + 2; break }
                        rel = br - pos + 1
                        continue
                    }
                    rel = max(9, buf.count - pos - 2)
                    if !fill() { return nil }
                }
                consumeTag()
                continue
            }

            // 3. Find the closing '>' while respecting quoted attribute values.
            var rel = 1
            var quote: UInt8 = 0
            var gt: Int?
            while gt == nil {
                let start = pos
                gt = buf.withUnsafeBufferPointer { p -> Int? in
                    guard let base = p.baseAddress else { return nil }
                    let n = p.count
                    var i = start + rel
                    while i < n {
                        if quote != 0 {
                            if let r = memchr(base + i, Int32(quote), n - i) {
                                i = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(r)) + 1
                                quote = 0
                            } else {
                                i = n
                            }
                        } else {
                            let c = p[i]
                            if c == 0x22 || c == 0x27 {
                                quote = c
                            } else if c == 0x3E {
                                return i
                            } else if c == 0x3C && i > start + 1 {
                                // Unquoted '<' inside a tag means the tag was malformed; recover by
                                // ending it here so we do not swallow the rest of the file.
                                return i - 1
                            }
                            i += 1
                        }
                    }
                    rel = i - start
                    return nil
                }
                if gt == nil && !fill() {
                    throw BackupParseError(message: "Unexpected end of file inside a tag (file may be truncated).")
                }
            }
            let e = gt!
            tagEnd = e

            let first = pos + 1 < buf.count ? buf[pos + 1] : 0
            if first == 0x2F {                       // </name>
                return RawTag(kind: .end, start: pos + 2, end: e, selfClosing: false)
            }
            if first == 0x3F || first == 0x21 {      // <?pi?> or <!DOCTYPE>
                return RawTag(kind: .other, start: pos + 1, end: e, selfClosing: false)
            }
            let selfClosing = e > pos + 1 && buf[e - 1] == 0x2F
            return RawTag(kind: .start, start: pos + 1, end: selfClosing ? e - 1 : e, selfClosing: selfClosing)
        }
    }
}

// MARK: - Attributes

@inline(__always) func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

func parseAttributes(_ p: UnsafeBufferPointer<UInt8>, from: Int, to e: Int,
                     names: inout [(Int, Int)], values: inout [(Int, Int)]) {
    names.removeAll(keepingCapacity: true)
    values.removeAll(keepingCapacity: true)
    guard let base = p.baseAddress else { return }
    var i = from
    while i < e {
        while i < e, isSpace(p[i]) { i += 1 }
        if i >= e { break }
        let ns = i
        while i < e, p[i] != 0x3D, !isSpace(p[i]) { i += 1 }
        let ne = i
        while i < e, isSpace(p[i]) { i += 1 }
        guard i < e, p[i] == 0x3D else { i += 1; continue }
        i += 1
        while i < e, isSpace(p[i]) { i += 1 }
        guard i < e else { break }
        let q = p[i]
        if q == 0x22 || q == 0x27 {
            i += 1
            let vs = i
            var ve = e
            if let r = memchr(base + i, Int32(q), e - i) {
                ve = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(r))
            }
            names.append((ns, ne))
            values.append((vs, ve))
            i = ve + 1
        } else {
            let vs = i
            while i < e, !isSpace(p[i]) { i += 1 }
            names.append((ns, ne))
            values.append((vs, i))
        }
    }
}

struct Attrs {
    let p: UnsafeBufferPointer<UInt8>
    let names: [(Int, Int)]
    let values: [(Int, Int)]

    func range(_ key: StaticString) -> (Int, Int)? {
        let kp = key.utf8Start
        let kn = key.utf8CodeUnitCount
        outer: for (idx, n) in names.enumerated() {
            guard n.1 - n.0 == kn else { continue }
            for k in 0..<kn where p[n.0 + k] != kp[k] { continue outer }
            return values[idx]
        }
        return nil
    }

    /// Decoded value, verbatim (the literal text "null" is preserved).
    func rawString(_ key: StaticString) -> String? {
        guard let r = range(key) else { return nil }
        return decodeXMLText(p, r.0, r.1)
    }

    /// Decoded value; nil when missing, empty-ish "null".
    func string(_ key: StaticString) -> String? {
        guard let r = range(key) else { return nil }
        if r.1 - r.0 == 4, p[r.0] == 0x6E, p[r.0 + 1] == 0x75, p[r.0 + 2] == 0x6C, p[r.0 + 3] == 0x6C { return nil }
        return decodeXMLText(p, r.0, r.1)
    }

    func int64(_ key: StaticString) -> Int64? {
        guard let r = range(key), r.1 > r.0 else { return nil }
        var i = r.0
        var neg = false
        if p[i] == 0x2D { neg = true; i += 1 }
        var v: Int64 = 0
        var any = false
        while i < r.1 {
            let c = p[i]
            guard c >= 0x30 && c <= 0x39 else { break }
            v = v &* 10 &+ Int64(c - 0x30)
            any = true
            i += 1
        }
        return any ? (neg ? -v : v) : nil
    }

    func int(_ key: StaticString) -> Int? { int64(key).map { Int(truncatingIfNeeded: $0) } }

    func base64(_ key: StaticString) -> Data? {
        guard let r = range(key), r.1 > r.0 else { return nil }
        if r.1 - r.0 == 4, p[r.0] == 0x6E, p[r.0 + 1] == 0x75 { return nil }   // "null"
        let raw = Data(UnsafeBufferPointer(rebasing: p[r.0..<r.1]))
        return Data(base64Encoded: raw, options: .ignoreUnknownCharacters)
    }
}

// MARK: - Entity decoding

@inline(__always) private func isValidXMLScalar(_ v: UInt32) -> Bool {
    v == 0x9 || v == 0xA || v == 0xD || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || (v >= 0x10000 && v <= 0x10FFFF)
}

private func entityValue(_ p: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> UInt32? {
    let n = e - s
    guard n > 0 else { return nil }
    if p[s] == 0x23 { // '#'
        var i = s + 1
        var radix: UInt32 = 10
        if i < e, p[i] == 0x78 || p[i] == 0x58 { radix = 16; i += 1 }
        guard i < e else { return nil }
        var v: UInt32 = 0
        while i < e {
            let c = p[i]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x61...0x66 where radix == 16: d = UInt32(c - 0x61 + 10)
            case 0x41...0x46 where radix == 16: d = UInt32(c - 0x41 + 10)
            default: return nil
            }
            v = v &* radix &+ d
            if v > 0x10FFFF { return 0xFFFD }
            i += 1
        }
        return v
    }
    func eq(_ str: StaticString) -> Bool {
        guard str.utf8CodeUnitCount == n else { return false }
        for k in 0..<n where p[s + k] != str.utf8Start[k] { return false }
        return true
    }
    if eq("amp") { return 0x26 }
    if eq("lt") { return 0x3C }
    if eq("gt") { return 0x3E }
    if eq("quot") { return 0x22 }
    if eq("apos") { return 0x27 }
    return nil
}

func decodeXMLText(_ p: UnsafeBufferPointer<UInt8>, _ s: Int, _ e: Int) -> String {
    var needsWork = false
    var i = s
    while i < e {
        let c = p[i]
        if c == 0x26 || (c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) { needsWork = true; break }
        i += 1
    }
    if !needsWork {
        return String(decoding: UnsafeBufferPointer(rebasing: p[s..<e]), as: UTF8.self)
    }

    var out: [UInt8] = []
    out.reserveCapacity(e - s)
    var pendingHigh: UInt32 = 0

    func appendScalar(_ value: UInt32) {
        let v = (value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) ? 0xFFFD : value
        switch v {
        case 0..<0x80:
            out.append(UInt8(v))
        case 0x80..<0x800:
            out.append(UInt8(0xC0 | (v >> 6)))
            out.append(UInt8(0x80 | (v & 0x3F)))
        case 0x800..<0x10000:
            out.append(UInt8(0xE0 | (v >> 12)))
            out.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (v & 0x3F)))
        default:
            out.append(UInt8(0xF0 | (v >> 18)))
            out.append(UInt8(0x80 | ((v >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (v & 0x3F)))
        }
    }
    func flushPending() {
        if pendingHigh != 0 { appendScalar(0xFFFD); pendingHigh = 0 }
    }

    i = s
    while i < e {
        let c = p[i]
        if c == 0x26 {
            var j = i + 1
            while j < e, j - i <= 12, p[j] != 0x3B { j += 1 }
            if j < e, p[j] == 0x3B, let v = entityValue(p, i + 1, j) {
                i = j + 1
                if v >= 0xD800 && v <= 0xDBFF {
                    flushPending()
                    pendingHigh = v
                } else if v >= 0xDC00 && v <= 0xDFFF {
                    if pendingHigh != 0 {
                        appendScalar(0x10000 + ((pendingHigh - 0xD800) << 10) + (v - 0xDC00))
                        pendingHigh = 0
                    } else {
                        appendScalar(0xFFFD)
                    }
                } else {
                    flushPending()
                    if isValidXMLScalar(v) { appendScalar(v) }
                }
                continue
            }
            flushPending()
            out.append(c)
            i += 1
            continue
        }
        flushPending()
        if c < 0x20 && c != 0x09 && c != 0x0A && c != 0x0D { i += 1; continue }
        out.append(c)
        i += 1
    }
    flushPending()
    return String(decoding: out, as: UTF8.self)
}
