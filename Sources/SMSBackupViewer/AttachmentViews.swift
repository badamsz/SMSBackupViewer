import SwiftUI
import AppKit

import SMSBackupCore

struct AttachmentStrip: View {
    let messageId: Int64
    let alignment: HorizontalAlignment

    @Environment(AppModel.self) private var model
    @State private var items: [AttachmentInfo] = []

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            ForEach(items) { info in
                AttachmentView(info: info)
            }
        }
        .task(id: messageId) {
            items = (try? model.store?.attachments(messageId: messageId)) ?? []
        }
    }
}

/// Small in-memory cache so scrolling back and forth doesn't re-decode images.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSNumber, NSImage>()
    init() { cache.countLimit = 400 }
    func image(_ id: Int64) -> NSImage? { cache.object(forKey: NSNumber(value: id)) }
    func set(_ img: NSImage, _ id: Int64) { cache.setObject(img, forKey: NSNumber(value: id)) }
}

struct AttachmentView: View {
    let info: AttachmentInfo

    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if info.isImage && !failed {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 300, maxHeight: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.quaternary)
                        .frame(width: 220, height: 160)
                        .overlay(ProgressView().controlSize(.small))
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: info.symbolName)
                        .font(.title2)
                        .frame(width: 28)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.fileName).lineLimit(1).truncationMode(.middle)
                        Text("\(info.contentType) · \(Formatters.bytes(Int64(info.size)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: 300, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open() }
        .help("Double-click to open · \(info.fileName)")
        .contextMenu {
            Button("Open") { open() }
            Button("Save As…") { saveAs() }
            if info.isImage {
                Button("Copy Image") { copyImage() }
            }
        }
        .task(id: info.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard info.isImage, image == nil else { return }
        if let cached = ThumbnailCache.shared.image(info.id) { image = cached; return }
        guard let store = model.store else { return }
        let id = info.id
        let data: Data? = await Task.detached(priority: .utility) {
            try? store.attachment(id: id)?.data
        }.value
        guard let data, let img = NSImage(data: data) else { failed = true; return }
        ThumbnailCache.shared.set(img, id)
        image = img
    }

    private func loadData() -> Data? { try? model.store?.attachment(id: info.id)?.data }

    private func open() {
        guard let data = loadData() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SMSBackupViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(info.id)-\(info.fileName)")
        do {
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    private func saveAs() {
        guard let data = loadData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = info.fileName
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func copyImage() {
        guard let data = loadData(), let img = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
}
