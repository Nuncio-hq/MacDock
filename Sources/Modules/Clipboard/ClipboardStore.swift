import AppKit
import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var copiedAt: Date
    var pinned: Bool
}

/// Polls NSPasteboard for new strings and keeps a persistent history.
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private let capacity = 200
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("MacDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard-history.json")
    }()

    init() { load() }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func copyBack(_ item: ClipboardItem, plain: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        lastChangeCount = pb.changeCount
    }

    func togglePin(_ item: ClipboardItem) {
        guard let i = items.firstIndex(of: item) else { return }
        items[i].pinned.toggle()
        save()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clearUnpinned() {
        items.removeAll { !$0.pinned }
        save()
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard let text = pb.string(forType: .string), !text.isEmpty else { return }
        items.removeAll { $0.text == text }
        items.insert(ClipboardItem(id: UUID(), text: text, copiedAt: Date(), pinned: false), at: 0)
        items.sort { $0.pinned && !$1.pinned }
        if items.count > capacity {
            let pinned = items.filter(\.pinned)
            var recent = items.filter { !$0.pinned }
            recent = Array(recent.prefix(capacity - pinned.count))
            items = pinned + recent
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        else { return }
        items = decoded
    }
}
