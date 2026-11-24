import SwiftUI
import SMSBackupCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Mode", selection: $model.sidebarMode) {
                ForEach(SidebarMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if model.sidebarMode == .messages {
                MessagesSidebar()
            } else {
                List(selection: $model.callFilter) {
                    ForEach(CallFilter.allCases) { f in
                        Label(f.rawValue, systemImage: f.symbol).tag(f)
                    }
                }
            }
        }
    }
}

private struct MessagesSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let searching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        List(selection: $model.selection) {
            if !searching {
                ForEach(model.conversations) { c in
                    ConversationRow(conversation: c)
                        .tag(SidebarItem.conversation(c.id))
                }
            } else {
                if !model.matchingConversations.isEmpty {
                    Section("Conversations") {
                        ForEach(model.matchingConversations) { c in
                            ConversationRow(conversation: c)
                                .tag(SidebarItem.conversation(c.id))
                        }
                    }
                }
                Section {
                    ForEach(model.searchHits) { hit in
                        SearchHitRow(hit: hit)
                            .tag(SidebarItem.searchHit(messageId: hit.message.id, conversationId: hit.message.conversationId))
                    }
                } header: {
                    if model.isSearching {
                        Text("Searching…")
                    } else {
                        Text(model.searchHits.count >= 500 ? "Messages (500+)" : "Messages (\(model.searchHits.count))")
                    }
                }
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search all messages")
        .task(id: model.searchText) { await model.runSearch() }
        .overlay {
            if searching && !model.isSearching && model.searchHits.isEmpty && model.matchingConversations.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: conversation.displayName, isGroup: conversation.isGroup)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.displayName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let d = conversation.lastDate {
                        Text(Formatters.listDate(d))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(conversation.lastSnippet ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .help("\(conversation.addresses.joined(separator: ", ")) · \(conversation.messageCount.formatted()) messages")
    }
}

struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.conversationName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Formatters.listDate(hit.message.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(Formatters.snippet(hit.snippet, prefix: hit.message.direction == .outgoing ? "You: " : nil))
                .font(.callout)
                .lineLimit(3)
        }
        .padding(.vertical, 2)
    }
}

struct Avatar: View {
    let name: String
    let isGroup: Bool

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first(where: \.isLetter) }
        return letters.isEmpty ? "" : String(letters).uppercased()
    }

    private var color: Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .brown]
        var h: UInt32 = 5381
        for b in name.utf8 { h = (h &* 33) ^ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            if isGroup {
                Image(systemName: "person.2.fill").font(.system(size: 13)).foregroundStyle(.white)
            } else if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: 15)).foregroundStyle(.white)
            } else {
                Text(initials).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: 34, height: 34)
    }
}
