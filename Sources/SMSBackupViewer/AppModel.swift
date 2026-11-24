import SwiftUI
import Observation
import SMSBackupCore

enum SidebarMode: String, CaseIterable, Identifiable {
    case messages = "Messages"
    case calls = "Calls"
    var id: String { rawValue }
}

enum SidebarItem: Hashable {
    case conversation(Int64)
    case searchHit(messageId: Int64, conversationId: Int64)
}

enum CallFilter: String, CaseIterable, Identifiable, Hashable {
    case all = "All Calls"
    case incoming = "Incoming"
    case outgoing = "Outgoing"
    case missed = "Missed"
    case voicemail = "Voicemail"
    case rejected = "Rejected / Blocked"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: return "phone"
        case .incoming: return "phone.arrow.down.left"
        case .outgoing: return "phone.arrow.up.right"
        case .missed: return "phone.down"
        case .voicemail: return "recordingtape"
        case .rejected: return "nosign"
        }
    }
    var types: [Int]? {
        switch self {
        case .all: return nil
        case .incoming: return [1]
        case .outgoing: return [2]
        case .missed: return [3]
        case .voicemail: return [4]
        case .rejected: return [5, 6]
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@MainActor
@Observable
final class ImportState: Identifiable {
    let id = UUID()
    let fileCount: Int
    var fileIndex = 0
    var fileName = ""
    var fraction: Double = 0
    var recordsSeen = 0
    var messagesAdded = 0
    var callsAdded = 0
    var isExtracting = false
    var finished = false
    var errorMessage: String?
    var results: [ImportResult] = []
    let cancelFlag = CancelFlag()

    init(fileCount: Int) { self.fileCount = fileCount }

    func update(_ p: ImportProgress, fileIndex: Int) {
        self.fileIndex = fileIndex
        fileName = p.fileName
        fraction = p.fraction
        recordsSeen = p.recordsSeen
        messagesAdded = p.messagesAdded
        callsAdded = p.callsAdded
        isExtracting = p.isExtracting
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var store: MessageStore?
    var openError: String?

    var conversations: [Conversation] = []
    var conversationIndex: [Int64: Conversation] = [:]

    var sidebarMode: SidebarMode = .messages
    var selection: SidebarItem?
    var callFilter: CallFilter? = .all

    var searchText = ""
    var searchHits: [SearchHit] = []
    var matchingConversations: [Conversation] = []
    var isSearching = false

    var showImporter = false
    var importState: ImportState?
    var dataVersion = 0

    init() {
        do {
            store = try MessageStore()
            reloadConversations()
        } catch {
            openError = error.localizedDescription
        }
    }

    var isEmpty: Bool { conversations.isEmpty }

    func conversation(id: Int64) -> Conversation? { conversationIndex[id] }

    func reloadConversations() {
        guard let store else { return }
        conversations = (try? store.conversations()) ?? []
        conversationIndex = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    }

    // MARK: Search

    func runSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let store else {
            searchHits = []
            matchingConversations = []
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))     // debounce
        if Task.isCancelled { return }
        isSearching = true
        let result = await Task.detached(priority: .userInitiated) { () -> ([SearchHit], [Conversation]) in
            let hits = (try? store.search(SearchQuery(text: q, limit: 500))) ?? []
            let convs = (try? store.conversations(filter: q, limit: 25)) ?? []
            return (hits, convs)
        }.value
        if Task.isCancelled { return }
        searchHits = result.0
        matchingConversations = result.1
        isSearching = false
    }

    var searchTerms: [String] { MessageStore.searchTerms(searchText) }

    // MARK: Import

    func importFiles(_ urls: [URL]) {
        let files = urls.filter { BackupArchive.isSupported($0) }
        guard !files.isEmpty, importState == nil || importState?.finished == true else { return }
        let state = ImportState(fileCount: files.count)
        importState = state
        let flag = state.cancelFlag
        let dbURL = store?.url ?? MessageStore.defaultDatabaseURL

        Task.detached(priority: .userInitiated) {
            var results: [ImportResult] = []
            var errorText: String?
            do {
                let importer = try MessageStore(url: dbURL)
                for (index, url) in files.enumerated() {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    var lastUpdate = Date.distantPast
                    var lastName = ""
                    let r = try importer.importFile(at: url, progress: { p in
                        let now = Date()
                        // Always deliver the first update for each file/phase so the label changes promptly.
                        let changed = p.fileName != lastName || p.isExtracting
                        lastName = p.fileName
                        guard changed || now.timeIntervalSince(lastUpdate) > 0.08 else { return }
                        lastUpdate = now
                        Task { @MainActor in state.update(p, fileIndex: index) }
                    }, isCancelled: { flag.isSet })
                    results.append(contentsOf: r)
                }
            } catch is CancellationError {
                errorText = "Import cancelled. Nothing from the current file was saved."
            } catch {
                errorText = error.localizedDescription
            }
            let finalResults = results
            let finalError = errorText
            await MainActor.run {
                state.results = finalResults
                state.errorMessage = finalError
                state.fraction = 1
                state.finished = true
                self.reloadConversations()
                self.dataVersion += 1
            }
        }
    }

    func deleteAllData() {
        guard let store else { return }
        try? store.deleteAllData()
        selection = nil
        searchText = ""
        reloadConversations()
        dataVersion += 1
    }
}
