import AppKit

/// Opens library files with the app chosen in Settings (OPEN-01).
enum FileOpener {
    static let previewApp = URL(filePath: "/System/Applications/Preview.app")

    /// Opens with the system default app.
    static func open(_ url: URL) {
        guard !logOpen(url) else { return }
        NSWorkspace.shared.open(url)
    }

    static func open(_ url: URL, withApp app: URL) {
        guard !logOpen(url) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// UI tests pass `-FolioOpenLog <file>` to record opens instead of launching another app.
    /// Returns true when the open was logged instead.
    @discardableResult
    static func logOpen(_ url: URL) -> Bool {
        guard let log = UserDefaults.standard.string(forKey: "FolioOpenLog") else { return false }
        let line = url.path + "\n"
        if let handle = FileHandle(forWritingAtPath: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: URL(filePath: log))
        }
        return true
    }

    static func open(web url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

}
