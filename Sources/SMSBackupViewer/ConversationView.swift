import SwiftUI
import AppKit
import SMSBackupCore

struct ConversationView: View {
    let conversationId: Int64
    let anchorMessageId: Int64?
    let highlightTerms: [String]

    @Environment(AppModel.self) private var model
    @State private var messages: [Message] = []
    @State private var hasEarlier = false
    @State private var hasLater = false
    @State private var loaded = false
    @State private var pendingScroll: (id: Int64, anchor: UnitPoint)?
    @State private var flashAnchor = false

    private let pageSize = 250

    private var conversation: Conversation? { model.conversation(id: conversationId) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    if hasEarlier {
                        Button("Load Earlier Messages") { loadEarlier() }
                            .buttonStyle(.link)
                            .padding(.vertical, 10)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(messages[index - 1].date, inSameDayAs: message.date) {
                            DaySeparator(date: message.date)
                        }
                        MessageBubble(message: message,
                                      isGroup: conversation?.isGroup ?? false,
                                      showSender: showSender(at: index),
                                      highlightTerms: highlightTerms,
                                      isAnchor: message.id == anchorMessageId && flashAnchor)
                            .id(message.id)
                    }
                    if hasLater {
                        Button("Load Later Messages") { loadLater() }
                            .buttonStyle(.link)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(anchorMessageId == nil ? .bottom : .center)
            .onChange(of: pendingScroll?.id) { _, _ in
                guard let target = pendingScroll else { return }
                pendingScroll = nil
                DispatchQueue.main.async {
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
            }
        }
        .overlay {
            if loaded && messages.isEmpty {
                ContentUnavailableView("No Messages", systemImage: "bubble.left")
            }
        }
        .navigationTitle(conversation?.displayName ?? "Conversation")
        .navigationSubtitle(subtitle)
        .task { initialLoad() }
    }

    private var subtitle: String {
        guard let c = conversation else { return "" }
        let addrs = c.addresses.joined(separator: ", ")
        let count = "\(c.messageCount.formatted()) messages"
        return addrs == c.displayName ? count : "\(addrs) · \(count)"
    }

    private func showSender(at index: Int) -> Bool {
        guard conversation?.isGroup == true else { return false }
        let m = messages[index]
        guard m.direction == .incoming else { return false }
        if index == 0 { return true }
        let prev = messages[index - 1]
        return prev.direction != .incoming || prev.sender != m.sender
            || !Calendar.current.isDate(prev.date, inSameDayAs: m.date)
    }

    private func cursor(_ m: Message) -> (date: Int64, id: Int64) { (DateUtil.millis(m.date), m.id) }

    private func initialLoad() {
        guard !loaded, let store = model.store else { return }
        if let anchor = anchorMessageId {
            let half = pageSize / 2
            messages = (try? store.messages(around: anchor, before: half, after: half)) ?? []
            if let idx = messages.firstIndex(where: { $0.id == anchor }) {
                hasEarlier = idx >= half
                hasLater = messages.count - idx - 1 >= half
            }
            loaded = true
            flashAnchor = true
            pendingScroll = (anchor, .center)
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.easeOut(duration: 0.6)) { flashAnchor = false }
            }
        } else {
            messages = (try? store.messages(conversationId: conversationId, limit: pageSize)) ?? []
            hasEarlier = messages.count >= pageSize
            loaded = true
            if let last = messages.last { pendingScroll = (last.id, .bottom) }
        }
    }

    private func loadEarlier() {
        guard let store = model.store, let first = messages.first else { return }
        let older = (try? store.messages(conversationId: conversationId, before: cursor(first), limit: pageSize)) ?? []
        hasEarlier = older.count >= pageSize
        guard !older.isEmpty else { return }
        messages.insert(contentsOf: older, at: 0)
        pendingScroll = (first.id, .top)
    }

    private func loadLater() {
        guard let store = model.store, let last = messages.last else { return }
        let newer = (try? store.messages(conversationId: conversationId, after: cursor(last), limit: pageSize)) ?? []
        hasLater = newer.count >= pageSize
        messages.append(contentsOf: newer)
    }
}

struct DaySeparator: View {
    let date: Date
    var body: some View {
        Text(Formatters.dayHeader(date))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
    }
}

struct MessageBubble: View {
    let message: Message
    let isGroup: Bool
    let showSender: Bool
    let highlightTerms: [String]
    let isAnchor: Bool

    @State private var hovering = false

    private var outgoing: Bool { message.direction == .outgoing }
    private var failed: Bool { message.kind == "sms" && message.box == 5 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if outgoing { Spacer(minLength: 80) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 3) {
                if showSender {
                    Text(message.senderDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                }
                if message.attachmentCount > 0 {
                    AttachmentStrip(messageId: message.id, alignment: outgoing ? .trailing : .leading)
                }
                if let subject = message.subject, !subject.isEmpty {
                    Text(subject).font(.callout.weight(.semibold)).padding(.horizontal, 10)
                }
                if let body = message.body, !body.isEmpty {
                    Text(highlightTerms.isEmpty ? AttributedString(body) : Formatters.highlight(body, terms: highlightTerms, onDark: outgoing))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(outgoing ? Color.white : Color.primary)
                        .background(bubbleColor, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(Color.yellow, lineWidth: isAnchor ? 3 : 0)
                        )
                }
                if hovering || failed {
                    HStack(spacing: 4) {
                        if failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
                        Text(message.date.formatted(date: .abbreviated, time: .shortened))
                        if message.kind == "mms" { Text("· MMS") }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: 560, alignment: outgoing ? .trailing : .leading)
            if !outgoing { Spacer(minLength: 80) }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            if let body = message.body, !body.isEmpty {
                Button("Copy Text") { copy(body) }
            }
            Button("Copy Message with Date") {
                copy("[\(message.date.formatted(date: .abbreviated, time: .shortened))] \(message.senderDisplay): \(message.body ?? "")")
            }
        }
    }

    private var bubbleColor: Color {
        if failed { return Color.red.opacity(0.7) }
        return outgoing ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.6)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
