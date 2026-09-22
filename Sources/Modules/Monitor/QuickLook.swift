import Quartz
import AppKit

/// Presents QLPreviewPanel for scanned items (Space / context menu).
/// QLPreviewPanel always calls its data source on the main thread.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    static let shared = QuickLookController()

    private var urls: [URL] = []

    func preview(_ urls: [URL], index: Int = 0) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        panel.currentPreviewItemIndex = index
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!,
                      previewItemAt index: Int) -> QLPreviewItem {
        urls[index] as QLPreviewItem
    }
}
