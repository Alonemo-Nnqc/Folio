import AppKit
import FolioCore
import Quartz
import UniformTypeIdentifiers

/// Commands that act on "the current items": the list selection in the library window, the open
/// paper in a reader tab. Menu items reach them through the responder chain (target nil), so the
/// same "条目" menu works in both kinds of window.
class FolioWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let model: AppModel

    init(model: AppModel, window: NSWindow) {
        self.model = model
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: Targets (overridden)

    /// Items (regular or standalone) the item commands act on.
    var targetItemIds: [String] { [] }
    /// A single file the file commands act on (a file row, or the paper open in a reader).
    var targetFileId: String? { nil }

    /// The context the item menus are built from.
    func menuContext() -> ItemMenuContext {
        var context = ItemMenuContext(scope: model.sidebarSelection, itemIds: targetItemIds, fileId: targetFileId)
        let fileId = targetFileId ?? targetItemIds.first.flatMap { model.defaultFile(of: $0)?.id }
        if let fileId, let file = model.snapshot.files[fileId] {
            context.openWithApps = Self.apps(toOpen: model.fileURL(file))
        }
        context.translatingItemIds = model.translations.activeItemIds
        return context
    }

    static func apps(toOpen url: URL) -> [(name: String, url: URL)] {
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        // The default app first, the rest alphabetically; at most 12 so the menu stays short.
        apps.sort { lhs, rhs in
            if lhs == defaultApp { return true }
            if rhs == defaultApp { return false }
            return FileManager.default.displayName(atPath: lhs.path)
                .localizedStandardCompare(FileManager.default.displayName(atPath: rhs.path)) == .orderedAscending
        }
        return apps.filter { $0.lastPathComponent != "Folio.app" }.prefix(12).map {
            ((FileManager.default.displayName(atPath: $0.path) as NSString).deletingPathExtension, $0)
        }
    }

    // MARK: Command dispatch (context menus and dynamic submenus)

    func perform(_ command: ItemMenuCommand, context: ItemMenuContext) {
        let ids = context.itemIds
        let fileIds = context.fileId.map { [$0] } ?? []
        switch command {
        case .open:
            if let fileId = context.fileId { model.open(fileId: fileId) } else { ids.forEach { model.open(itemId: $0) } }
        case .openInReader: open(context, with: .reader)
        case .openWithPreview: open(context, with: .preview)
        case .openWithApp(let url): open(context, with: .app(url))
        case .openWithOtherApp: chooseAppAndOpen(context)
        case .quickLook: quickLook()
        case .revealInFinder: model.revealInFinder(itemIds: ids, fileIds: fileIds)
        case .addToGroup(let groupId): model.addItems(ids, toGroup: groupId)
        case .toggleTag(let tagId): model.toggleTag(tagId, on: ids)
        case .newTag: model.activeSheet = .tagEditor(tagId: nil, applyTo: ids)
        case .setReadStatus(let status): model.setReadStatus(status, on: ids)
        case .setRating(let value): model.setRating(value, on: ids)
        case .copyCitation(let style): model.copyCitations(style: style, itemIds: ids)
        case .addFiles: if let id = ids.first { model.chooseFilesToAttach(to: id) }
        case .retrieve: ids.forEach(model.importer.retrieve(itemId:))
        case .manualMatch: if let id = ids.first { model.activeSheet = .manualMatch(itemId: id) }
        case .removeFromGroup: model.removeFromCurrentGroup(ids)
        case .trash: model.trashItems(ids)
        case .restore: model.restoreItems(ids)
        case .purge: model.confirmPurge(ids)
        case .setDefaultFile(let fileId): model.setDefaultFile(fileId)
        case .trashFile: model.trashFiles(fileIds)
        case .translate: if let fileId = sourceFileId(context) { model.translations.requestTranslation(fileId: fileId) }
        case .cancelTranslation:
            let itemId = context.fileId.flatMap { model.snapshot.files[$0]?.itemId } ?? ids.first
            if let itemId { model.translations.cancel(itemId: itemId) }
        case .editNote: if let id = ids.first ?? context.fileId.flatMap({ model.snapshot.files[$0]?.itemId }) { editNote(itemId: id) }
        case .exportNote: if let id = ids.first { model.exportNote(itemId: id) }
        }
    }

    /// The file a file-level command means: the clicked file, else the item's default file.
    private func sourceFileId(_ context: ItemMenuContext) -> String? {
        context.fileId ?? context.itemIds.first.flatMap { model.defaultFile(of: $0)?.id }
    }

    private func open(_ context: ItemMenuContext, with mode: AppModel.OpenMode) {
        if let fileId = context.fileId {
            model.open(fileId: fileId, mode: mode)
        } else {
            for id in context.itemIds { model.open(itemId: id, mode: mode) }
        }
    }

    private func chooseAppAndOpen(_ context: ItemMenuContext) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = "打开"
        panel.message = "选择用来打开文件的应用"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            self?.open(context, with: .app(app))
        }
    }

    /// Shows the note editor for an item (overridden: the library uses its inspector, a reader its side panel).
    func editNote(itemId: String) {}

    func quickLook() {}

    // MARK: Menu actions

    @objc func openSelection(_ sender: Any?) { perform(.open, context: menuContext()) }
    @objc func openInReader(_ sender: Any?) { perform(.openInReader, context: menuContext()) }
    @objc func openWithPreview(_ sender: Any?) { perform(.openWithPreview, context: menuContext()) }
    @objc func revealInFinder(_ sender: Any?) { perform(.revealInFinder, context: menuContext()) }
    @objc func attachFiles(_ sender: Any?) { perform(.addFiles, context: menuContext()) }
    @objc func retrieveMetadata(_ sender: Any?) { perform(.retrieve, context: menuContext()) }
    @objc func manualMatch(_ sender: Any?) { perform(.manualMatch, context: menuContext()) }
    @objc func translateDocument(_ sender: Any?) { perform(.translate, context: menuContext()) }
    @objc func cancelTranslation(_ sender: Any?) { perform(.cancelTranslation, context: menuContext()) }
    @objc func editNote(_ sender: Any?) { perform(.editNote, context: menuContext()) }
    @objc func exportNote(_ sender: Any?) { perform(.exportNote, context: menuContext()) }
    @objc func quickLookSelection(_ sender: Any?) { quickLook() }

    @objc func copyCitation(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, CitationStyleOption.allCases.indices.contains(item.tag) else { return }
        model.copyCitations(style: CitationStyleOption.allCases[item.tag], itemIds: citableIds)
    }

    @objc func exportBibTeX(_ sender: Any?) { model.exportBibTeX(itemIds: citableIds) }

    /// Citation commands with nothing selected act on the whole view (CITE-02).
    var citableIds: [String]? { targetItemIds.isEmpty ? nil : targetItemIds }

    /// Toolbar buttons share the menu rules.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let action = item.action else { return true }
        return validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let context = menuContext()
        let items = context.itemIds.compactMap { model.snapshot.items[$0] }
        let single = items.count == 1 ? items.first : nil
        let file = context.fileId.flatMap { model.snapshot.files[$0] } ?? single.flatMap { model.defaultFile(of: $0.id) }
        let inTrash = model.sidebarSelection == .trash && context.fileId == nil
        switch menuItem.action {
        case #selector(openSelection(_:)), #selector(revealInFinder(_:)):
            return !items.isEmpty || file != nil
        case #selector(openInReader(_:)), #selector(openWithPreview(_:)):
            return file?.isPDF ?? false
        case #selector(quickLookSelection(_:)):
            return file != nil
        case #selector(attachFiles(_:)):
            return single?.kind == .regular && !inTrash
        case #selector(retrieveMetadata(_:)):
            return !items.isEmpty && !inTrash && items.allSatisfy { $0.metadataState != .pending }
        case #selector(manualMatch(_:)):
            return single?.kind == .standalone && !inTrash
        case #selector(translateDocument(_:)):
            guard let file, file.isPDF, file.translationOf == nil, !inTrash else { return false }
            return !model.translations.activeItemIds.contains(file.itemId)
        case #selector(cancelTranslation(_:)):
            return file.map { model.translations.activeItemIds.contains($0.itemId) } ?? false
        case #selector(editNote(_:)):
            return (single != nil || file != nil) && !inTrash
        case #selector(exportNote(_:)):
            return single.map { model.snapshot.notedItems.contains($0.id) } ?? false
        case #selector(copyCitation(_:)), #selector(exportBibTeX(_:)):
            return !model.citationEntries(citableIds).isEmpty
        default:
            return true
        }
    }
}
