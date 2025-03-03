import Foundation
import Lowtech
import QuickLookUI

final class QuickLooker: QLPreviewPanelDataSource {
    init(urls: [URL]) {
        self.urls = urls
    }

    static var shared: QuickLooker?

    let urls: [URL]

    static func quicklook(url: URL) {
        shared = QuickLooker(urls: [url])
        shared?.quicklook()
    }
    static func quicklook(urls: [URL]) {
        shared = QuickLooker(urls: urls)
        shared?.quicklook()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[safe: index] as NSURL?
    }

    func quicklook() {
        guard let ql = QLPreviewPanel.shared() else { return }

        focus()
        ql.makeKeyAndOrderFront(nil)
        ql.orderFrontRegardless()
        ql.dataSource = self
        ql.currentPreviewItemIndex = 0
        ql.reloadData()
    }
}
