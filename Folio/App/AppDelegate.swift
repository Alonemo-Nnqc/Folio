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
        libraryWindowController.showWindow(nil)
        libraryWindowController.window?.makeKeyAndOrderFront(nil)
    }

    var settingsWindow: SettingsWindowController? { settingsWindowController }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil { settingsWindowController = SettingsWindowController(model: model) }
        settingsWindowController?.showWindow(nil)
    }

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
