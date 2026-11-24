import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SMSBackupCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showImporter = true
                } label: {
                    Label("Import Backup", systemImage: "square.and.arrow.down")
                }
                .help("Import SMS Backup & Restore files (sms-*.xml, calls-*.xml, or a .zip of them)")
            }
        }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [.xml, .zip],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let backups = urls.filter { BackupArchive.isSupported($0) }
            model.importFiles(backups)
            return !backups.isEmpty
        }
        .sheet(item: $model.importState) { state in
            ImportProgressView(state: state)
        }
        .alert("Couldn't open the database", isPresented: .constant(model.openError != nil)) {
            Button("Quit") { NSApp.terminate(nil) }
        } message: {
            Text(model.openError ?? "")
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.sidebarMode == .calls {
                CallsView()
            } else if model.isEmpty {
                EmptyArchiveView()
            } else {
                switch model.selection {
                case .conversation(let id):
                    ConversationView(conversationId: id, anchorMessageId: nil, highlightTerms: [])
                        .id("c\(id)-\(model.dataVersion)")
                case .searchHit(let messageId, let conversationId):
                    ConversationView(conversationId: conversationId, anchorMessageId: messageId, highlightTerms: model.searchTerms)
                        .id("h\(messageId)-\(model.dataVersion)")
                case nil:
                    ContentUnavailableView("No Conversation Selected",
                                           systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Pick a conversation or search your messages."))
                }
            }
        }
    }
}

struct EmptyArchiveView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Import an SMS Backup & Restore file")
                .font(.title2.weight(.semibold))
            Text("Drag **sms-*.xml** or **calls-*.xml** files (or a **.zip** of them) here, or click Import.\nBackups are indexed into a private local database for fast searching — the original files are never modified.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button {
                model.showImporter = true
            } label: {
                Label("Import Backup…", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ImportProgressView: View {
    let state: ImportState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if state.finished {
                Label(state.errorMessage == nil ? "Import complete" : "Import finished with a problem",
                      systemImage: state.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(state.errorMessage == nil ? Color.green : Color.orange)
                ForEach(Array(state.results.enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.fileName).font(.callout.weight(.medium))
                        Text("\(r.recordsSeen.formatted()) records · \(r.messagesAdded.formatted()) new messages · \(r.callsAdded.formatted()) new calls · \(r.duplicatesSkipped.formatted()) duplicates skipped")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let e = state.errorMessage {
                    Text(e).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Importing \(state.fileName.isEmpty ? "…" : state.fileName)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if state.fileCount > 1 {
                    Text("File \(state.fileIndex + 1) of \(state.fileCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if state.isExtracting {
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("Unzipping archive…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: state.fraction)
                }
                Text("\(state.recordsSeen.formatted()) records read · \(state.messagesAdded.formatted()) messages · \(state.callsAdded.formatted()) calls added")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack {
                    Spacer()
                    Button("Cancel") { state.cancelFlag.set() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(22)
        .frame(width: 460)
        .interactiveDismissDisabled(!state.finished)
    }
}
