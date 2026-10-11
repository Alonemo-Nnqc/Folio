import AppKit

final class ReaderWindowController: FolioWindowController {
    @objc func printDocument(_ sender: Any?) {}
    @objc func findNext(_ sender: Any?) {}
    @objc func findPrevious(_ sender: Any?) {}
}

enum ReaderMenus {
    static func menus() -> [(String, NSMenu)] { [] }
    static func viewItems() -> [NSMenuItem] { [] }
}

final class ReaderCoordinator {
    private weak var model: AppModel?
    init(model: AppModel) { self.model = model }
    func open(fileId: String, inBackground: Bool) {
        guard let model, let file = model.snapshot.files[fileId] else { return }
        FileOpener.open(model.fileURL(file), withApp: FileOpener.previewApp)
    }
}
