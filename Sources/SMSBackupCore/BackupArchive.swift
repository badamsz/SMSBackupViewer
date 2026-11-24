import Foundation

/// Support for zipped backups (e.g. "sms-20261119.zip" or a zip of a whole backup folder).
/// Archives are expanded with macOS's built-in `ditto` into a temporary folder, every .xml inside
/// is imported, and the temporary folder is deleted afterwards.
public enum BackupArchive {
    public static let supportedExtensions: Set<String> = ["xml", "zip"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased()) || isZip(url)
    }

    /// True if the file starts with a zip local-file or empty-archive signature.
    public static func isZip(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4), head.count == 4 else { return false }
        let b = [UInt8](head)
        return b[0] == 0x50 && b[1] == 0x4B && (b[2] == 0x03 && b[3] == 0x04 || b[2] == 0x05 && b[3] == 0x06)
    }

    public struct Extracted {
        public let directory: URL
        public let xmlFiles: [URL]
        public func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Expands `url` into a new temporary directory and returns the XML files found inside,
    /// SMS backups first, then call logs, then anything else.
    public static func extract(_ url: URL, isCancelled: (() -> Bool)? = nil) throws -> Extracted {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SMSBackupViewer-unzip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--norsrc", url.path, dir.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? fm.removeItem(at: dir)
            throw BackupParseError(message: "Couldn't run /usr/bin/ditto to unzip \(url.lastPathComponent): \(error.localizedDescription)")
        }
        while process.isRunning {
            if isCancelled?() == true {
                process.terminate()
                process.waitUntilExit()
                try? fm.removeItem(at: dir)
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard process.terminationStatus == 0 else {
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? fm.removeItem(at: dir)
            let hint = err.lowercased().contains("password") || err.lowercased().contains("encrypt")
                ? " Password-protected zips aren't supported; unzip it in Finder first."
                : ""
            throw BackupParseError(message: "Couldn't unzip \(url.lastPathComponent)\(err.isEmpty ? "" : ": \(err)").\(hint)")
        }

        var files: [URL] = []
        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let f as URL in walker {
                let name = f.lastPathComponent
                if f.pathComponents.contains("__MACOSX") || name.hasPrefix("._") { continue }
                if f.pathExtension.lowercased() == "xml",
                   (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    files.append(f)
                }
            }
        }
        func rank(_ u: URL) -> Int {
            let n = u.lastPathComponent.lowercased()
            return n.hasPrefix("sms") ? 0 : n.hasPrefix("calls") ? 1 : 2
        }
        files.sort { (rank($0), $0.lastPathComponent) < (rank($1), $1.lastPathComponent) }

        if files.isEmpty {
            try? fm.removeItem(at: dir)
            throw BackupParseError(message: "\(url.lastPathComponent) doesn't contain any .xml backup files.")
        }
        return Extracted(directory: dir, xmlFiles: files)
    }
}

extension MessageStore {
    /// Imports an .xml backup, or every .xml inside a .zip. Returns one result per XML file imported.
    public func importFile(at url: URL,
                           progress: ((ImportProgress) -> Void)? = nil,
                           isCancelled: (() -> Bool)? = nil) throws -> [ImportResult] {
        guard BackupArchive.isZip(url) else {
            return [try importBackup(at: url, progress: progress, isCancelled: isCancelled)]
        }
        progress?(ImportProgress(fileName: url.lastPathComponent, bytesRead: 0, totalBytes: 0, recordsSeen: 0,
                                 messagesAdded: 0, callsAdded: 0, isExtracting: true))
        let extracted = try BackupArchive.extract(url, isCancelled: isCancelled)
        defer { extracted.cleanUp() }

        var results: [ImportResult] = []
        for xml in extracted.xmlFiles {
            let label = "\(url.lastPathComponent) › \(xml.lastPathComponent)"
            results.append(try importBackup(at: xml, displayName: label, sourcePath: url.path, progress: progress, isCancelled: isCancelled))
        }
        return results
    }
}
