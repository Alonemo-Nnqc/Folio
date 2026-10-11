import AppKit

/// Owns the app-wide objects: the model, the library window, the reader tabs and the settings window.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private(set) var model: AppModel!
    private(set) var libraryWindowController: LibraryWindowController!
    private var settingsWindowController: SettingsWindowController?
    private var pendingOpens: [URL] = []
    private var didFinishLaunching = false

    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Full Screen is in our own View menu; don't let AppKit add a second one.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        model = AppModel()
        MainMenu.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        libraryWindowController = LibraryWindowController(model: model)
        model.libraryWindow = libraryWindowController.window
        libraryWindowController.showWindow(nil)
        didFinishLaunching = true
        flushPendingOpens()
    }

    /// Unsaved annotations are written before quitting (READER-05).
    func applicationWillTerminate(_ notification: Notification) {
        model.translations.cancelAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.readers.saveAll() else {
            let alert = NSAlert()
            alert.messageText = "部分批注无法保存"
            alert.informativeText = "仍要退出吗？未保存的批注会丢失。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "退出")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings the library back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// PDFs opened with Folio from Finder (or `open -a Folio x.pdf`) are imported.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpens += urls.filter(\.isFileURL)
        flushPendingOpens()
    }

    private func flushPendingOpens() {
        guard didFinishLaunching, !pendingOpens.isEmpty else { return }
        let urls = pendingOpens
        pendingOpens = []
        model.importer.importFiles(urls, toGroup: model.sidebarSelection.groupId)
    }

    // MARK: Actions

    @objc func showLibrary(_ sender: Any?) {
        guard let library = libraryWindowController.window else { return }
        // A closed library tab comes back into the tab group of the open papers, as the first tab.
        if !library.isVisible, let paper = NSApp.windows.first(where: {
            $0.isVisible && $0 !== library && $0.tabbingIdentifier == library.tabbingIdentifier
        }) {
            let first = paper.tabGroup?.windows.first ?? paper
            first.addTabbedWindow(library, ordered: .below)
        }
        libraryWindowController.showWindow(nil)
        library.makeKeyAndOrderFront(nil)
    }

    var settingsWindow: SettingsWindowController? { settingsWindowController }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController(model: model) }
        settingsWindowController?.showWindow(nil)
    }

    // Library commands that also work while a paper tab is in front: bring the library forward first.
    @objc func addFiles(_ sender: Any?) { showLibrary(nil); model.chooseFilesToImport() }
    @objc func addByIdentifier(_ sender: Any?) { showLibrary(nil); model.activeSheet = .identifierAdd }
    @objc func newGroup(_ sender: Any?) { showLibrary(nil); model.createGroup() }
    @objc func newTag(_ sender: Any?) { model.activeSheet = .tagEditor(tagId: nil, applyTo: []) }
    @objc func importFromZotero(_ sender: Any?) { showLibrary(nil); model.activeSheet = .zoteroImport }

    @objc func revealLibraryInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([model.library.root])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showLibrary(_:)) {
            menuItem.state = libraryWindowController?.window?.isKeyWindow == true ? .on : .off
        }
        return true
    }
}
