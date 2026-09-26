import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet { flushPendingOpens() }
    }
    private var pendingOpens: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// PDFs opened with Folio from Finder (or `open -a Folio x.pdf`) are imported.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpens += urls.filter(\.isFileURL)
        flushPendingOpens()
    }

    private func flushPendingOpens() {
        guard let model, !pendingOpens.isEmpty else { return }
        let urls = pendingOpens
        pendingOpens = []
        model.importer.importFiles(urls, toGroup: model.sidebarSelection.groupId)
    }
}
