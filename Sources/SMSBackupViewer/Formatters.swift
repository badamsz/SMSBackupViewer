import SwiftUI
import UniformTypeIdentifiers
import SMSBackupCore

enum Formatters {
    static func listDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(date: .numeric, time: .omitted)
    }

    static func dayHeader(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    static func duration(_ seconds: Int) -> String {
        if seconds <= 0 { return "—" }
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// Turns an FTS snippet with «match» markers into an AttributedString with highlighted matches.
    static func snippet(_ s: String, prefix: String? = nil) -> AttributedString {
        var out = AttributedString(prefix ?? "")
        out.foregroundColor = .secondary
        var rest = Substring(s.replacingOccurrences(of: "\n", with: " "))
        while let open = rest.firstIndex(of: "«") {
            out += AttributedString(String(rest[..<open]))
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "»") {
                var hit = AttributedString(String(rest[afterOpen..<close]))
                hit.font = .callout.bold()
                hit.backgroundColor = Color.yellow.opacity(0.35)
                out += hit
                rest = rest[rest.index(after: close)...]
            } else {
                rest = rest[afterOpen...]
            }
        }
        out += AttributedString(String(rest))
        return out
    }

    /// Highlights each search term inside `text`.
    static func highlight(_ text: String, terms: [String], onDark: Bool) -> AttributedString {
        var a = AttributedString(text)
        for term in terms where !term.isEmpty {
            var searchStart = a.startIndex
            while searchStart < a.endIndex,
                  let r = a[searchStart...].range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                a[r].backgroundColor = onDark ? Color.yellow.opacity(0.55) : Color.yellow.opacity(0.6)
                a[r].foregroundColor = .black
                searchStart = r.upperBound
            }
        }
        return a
    }
}

extension AttachmentInfo {
    var symbolName: String {
        if isImage { return "photo" }
        if isVideo { return "film" }
        if isAudio { return "waveform" }
        let ct = contentType.lowercased()
        if ct.contains("vcard") { return "person.crop.rectangle" }
        if ct.contains("calendar") { return "calendar" }
        if ct.hasPrefix("text/") { return "doc.text" }
        if ct.contains("pdf") { return "doc.richtext" }
        return "doc"
    }

    var fileName: String {
        let ext = UTType(mimeType: contentType)?.preferredFilenameExtension
        if var n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty {
            n = n.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            if (n as NSString).pathExtension.isEmpty, let ext { n += ".\(ext)" }
            return n
        }
        return "attachment-\(id)" + (ext.map { ".\($0)" } ?? "")
    }
}
