import SwiftUI
import AppKit
import SMSBackupCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Archive", systemImage: "archivebox") }
            MCPSettingsView()
                .tabItem { Label("MCP Server", systemImage: "server.rack") }
        }
        .frame(width: 640, height: 480)
    }
}

// MARK: - Archive

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var stats: StoreStats?
    @State private var sources: [ImportSource] = []
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("Database") {
                LabeledContent("Location") {
                    HStack {
                        Text(model.store?.url.path ?? "—")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            if let url = model.store?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    }
                }
                if let s = stats {
                    LabeledContent("Messages", value: "\(s.messages.formatted()) (\(s.sms.formatted()) SMS, \(s.mms.formatted()) MMS)")
                    LabeledContent("Conversations", value: s.conversations.formatted())
                    LabeledContent("Calls", value: s.calls.formatted())
                    LabeledContent("Attachments", value: "\(s.attachments.formatted()) · \(Formatters.bytes(s.attachmentBytes))")
                    if let f = s.firstMessage, let l = s.lastMessage {
                        LabeledContent("Date range", value: "\(f.formatted(date: .abbreviated, time: .omitted)) – \(l.formatted(date: .abbreviated, time: .omitted))")
                    }
                    LabeledContent("Size on disk", value: Formatters.bytes(model.store?.fileSize ?? 0))
                    LabeledContent("Full-text search", value: model.store?.ftsEnabled == true ? "SQLite FTS5" : "Basic (FTS5 unavailable)")
                }
            }
            Section("Imported Files") {
                if sources.isEmpty {
                    Text("Nothing imported yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { src in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(src.fileName)
                            Text("\(src.importedAt.formatted(date: .abbreviated, time: .shortened)) · \(src.messagesAdded.formatted()) messages, \(src.callsAdded.formatted()) calls added")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .help(src.path)
                    }
                }
            }
            Section {
                Button("Delete All Imported Data…", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Removes the local index only. Your original backup files are not touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: model.dataVersion) { refresh() }
        .confirmationDialog("Delete all imported messages, calls and attachments?", isPresented: $confirmDelete) {
            Button("Delete Everything", role: .destructive) {
                model.deleteAllData()
                refresh()
            }
        } message: {
            Text("You can re-import your backup files afterwards.")
        }
    }

    private func refresh() {
        stats = try? model.store?.stats()
        sources = (try? model.store?.sources()) ?? []
    }
}

// MARK: - MCP

struct MCPSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: String?

    static let serverName = "sms-backup"

    private var binaryURL: URL {
        // The MCP server ships next to the app executable: SMS Backup Viewer.app/Contents/MacOS/smsbackup-mcp
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
            .appendingPathComponent("smsbackup-mcp")
    }

    private var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binaryURL.path) }

    private var dbPath: String { model.store?.url.path ?? MessageStore.defaultDatabaseURL.path }

    private var serverEntry: [String: Any] {
        ["command": binaryURL.path, "args": ["--db", dbPath]]
    }

    private var configSnippet: String {
        let obj: [String: Any] = ["mcpServers": [Self.serverName: serverEntry]]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private var claudeCodeCommand: String {
        "claude mcp add --scope user \(Self.serverName) -- \(shellQuote(binaryURL.path)) --db \(shellQuote(dbPath))"
    }

    var body: some View {
        Form {
            Section {
                Text("The app includes a local MCP server so AI assistants like Claude can search your archived texts and call log. It runs only on this Mac, over stdio, and reads the same local database as this app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Server binary") {
                    HStack(spacing: 6) {
                        Image(systemName: binaryExists ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(binaryExists ? Color.green : Color.red)
                        Text(binaryURL.path)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if !binaryExists {
                    Text("smsbackup-mcp wasn't found next to the app. Build with build-app.sh so it's bundled inside the .app.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Claude Desktop") {
                HStack {
                    Button("Add to Claude Desktop") { installClaudeDesktop() }
                        .disabled(!binaryExists)
                    Button("Copy JSON Config") { copy(configSnippet, "Config copied.") }
                }
                ScrollView(.horizontal) {
                    Text(configSnippet)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }

            Section("Claude Code") {
                HStack(alignment: .top) {
                    Text(claudeCodeCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") { copy(claudeCodeCommand, "Command copied.") }
                }
            }

            if let status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func copy(_ s: String, _ message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        status = message
    }

    private func installClaudeDesktop() {
        let fm = FileManager.default
        let configURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        do {
            var root: [String: Any] = [:]
            if fm.fileExists(atPath: configURL.path) {
                let data = try Data(contentsOf: configURL)
                if !data.isEmpty {
                    guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        status = "claude_desktop_config.json isn't a JSON object; not modified. Use Copy JSON Config instead."
                        return
                    }
                    root = parsed
                }
                let backup = configURL.appendingPathExtension("bak")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: configURL, to: backup)
            } else {
                try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers[Self.serverName] = serverEntry
            root["mcpServers"] = servers
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: configURL, options: .atomic)
            status = "Added \"\(Self.serverName)\" to Claude Desktop (previous config saved as .bak). Quit and reopen Claude to load it."
        } catch {
            status = "Couldn't update Claude Desktop config: \(error.localizedDescription)"
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
