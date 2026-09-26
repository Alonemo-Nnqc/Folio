import AppKit

/// Opens library files with the app chosen in Settings (OPEN-01).
enum FileOpener {
    static func open(_ url: URL, settings: AppSettings) {
        // UI tests pass `-FolioOpenLog <file>` to record opens instead of launching another app.
        if let log = UserDefaults.standard.string(forKey: "FolioOpenLog") {
            let line = url.path + "\n"
            if let handle = FileHandle(forWritingAtPath: log) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: URL(filePath: log))
            }
            return
        }
        switch settings.openWith {
        case .system:
            NSWorkspace.shared.open(url)
        case .preview:
            openWithApp(URL(filePath: "/System/Applications/Preview.app"), url: url)
        case .custom:
            if settings.openWithAppPath.isEmpty {
                NSWorkspace.shared.open(url)
            } else {
                openWithApp(URL(filePath: settings.openWithAppPath), url: url)
            }
        }
    }

    static func open(web url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private static func openWithApp(_ app: URL, url: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
