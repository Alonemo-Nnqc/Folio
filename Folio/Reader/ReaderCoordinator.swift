import AppKit
import FolioCore

/// Opens papers as native tabs next to the library (UI-09, READER-01) and remembers which were open (READER-07).
final class ReaderCoordinator {
    private weak var model: AppModel?
    private var readers: [String: ReaderWindowController] = [:]
    private var order: [String] = []
    private static let openTabsKey = "openReaderTabs"
    private var isTerminating = false

    init(model: AppModel) {
        self.model = model
    }

    var openFileIds: [String] { order }

    func reader(for fileId: String) -> ReaderWindowController? { readers[fileId] }

    func open(fileId: String, inBackground: Bool = false) {
        guard let model else { return }
        if let existing = readers[fileId] {
            if !inBackground { existing.window?.makeKeyAndOrderFront(nil) }
            return
        }
        guard let reader = ReaderWindowController(model: model, fileId: fileId), let window = reader.window else { return }
        readers[fileId] = reader
        order.append(fileId)
        persist()
        // Join the tab group of the window the user is in (the library, or another paper).
        let host = (NSApp.keyWindow?.windowController as? FolioWindowController)?.window ?? model.libraryWindow
        if let host, host.isVisible, host.tabbingIdentifier == window.tabbingIdentifier {
            host.addTabbedWindow(window, ordered: .above)
            if inBackground {
                host.tabGroup?.selectedWindow = host
                host.makeKeyAndOrderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            window.center()
            reader.showWindow(nil)
        }
    }

    func readerDidClose(_ reader: ReaderWindowController) {
        readers[reader.fileId] = nil
        order.removeAll { $0 == reader.fileId }
        if !isTerminating { persist() }
    }

    /// Saves annotations and positions of every open paper (app termination).
    @discardableResult
    func saveAll() -> Bool {
        isTerminating = true
        var ok = true
        for reader in readers.values {
            reader.savePosition()
            ok = reader.save() && ok
        }
        return ok
    }

    /// Reopens the papers that were open when Folio last quit.
    func restoreTabs() {
        guard let model, model.settings.reopenReaderTabs, !UserDefaults.standard.bool(forKey: "FolioUITesting") else { return }
        let ids = UserDefaults.standard.stringArray(forKey: Self.openTabsKey) ?? []
        for id in ids where model.snapshot.files[id] != nil {
            open(fileId: id, inBackground: true)
        }
    }

    private func persist() {
        guard !UserDefaults.standard.bool(forKey: "FolioUITesting") else { return }
        UserDefaults.standard.set(order, forKey: Self.openTabsKey)
    }
}
