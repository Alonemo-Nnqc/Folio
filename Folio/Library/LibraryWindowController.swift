import AppKit
import FolioCore
import Quartz
import SwiftUI

/// The library window: sidebar, item list and inspector in a native split view, with a customizable
/// toolbar (UI-01/03). It is the first tab of the window's tab group; papers open as further tabs (UI-09).
final class LibraryWindowController: FolioWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    static let tabbingIdentifier = "Folio"

    let splitViewController: LibrarySplitViewController
    private var observers: [ObservationLoop] = []
    private weak var searchItem: NSSearchToolbarItem?
    private var lastSearchFocusRequest = 0
    private var presentedSheet: NSViewController?
    private var shownLoadError: String?

    init(model: AppModel) {
        splitViewController = LibrarySplitViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = splitViewController
        window.title = "所有文献"
        window.minSize = NSSize(width: 900, height: 560)
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.tabbingMode = .preferred
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("libraryWindow")
        super.init(model: model, window: window)

        // "2": the layout changed (sidebar button at the sidebar's edge); old saved layouts are not reused.
        let toolbar = NSToolbar(identifier: "LibraryToolbar2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        // UI tests must not overwrite the user's toolbar layout.
        toolbar.autosavesConfiguration = !UserDefaults.standard.bool(forKey: "FolioUITesting")
        window.toolbar = toolbar

        if !window.setFrameUsingName("FolioLibraryWindow") {
            window.setContentSize(NSSize(width: 1320, height: 820))
            window.center()
        }
        window.setFrameAutosaveName("FolioLibraryWindow")
        startObserving()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private func startObserving() {
        observers.append(ObservationLoop { [weak self] in
            guard let self, let window = self.window else { return }
            window.title = self.model.title
            window.subtitle = self.model.subtitle
            window.tab.title = "文献库"
        })
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            let request = self.model.searchFocusRequest
            if request != self.lastSearchFocusRequest {
                self.lastSearchFocusRequest = request
                self.focusSearchField()
            }
            // Keep the field in step when search is changed elsewhere (scope bar, preview hooks).
            if let field = self.searchItem?.searchField, field.stringValue != self.model.search.text,
               field.currentEditor() == nil {
                field.stringValue = self.model.search.text
            }
        })
        observers.append(ObservationLoop { [weak self] in
            guard let self else { return }
            self.syncSheet(self.model.activeSheet)
        })
        observers.append(ObservationLoop { [weak self] in
            guard let self, let message = self.model.loadError, message != self.shownLoadError else { return }
            self.shownLoadError = message
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "无法打开文献库"
            alert.informativeText = message + "\n\n可以在 设置 ▸ 文献库 中查看或更改文献库位置。"
            alert.addButton(withTitle: "好")
            alert.addButton(withTitle: "打开设置…")
            DispatchQueue.main.async {
                guard let window = self.window else { return }
                alert.beginSheetModal(for: window) { response in
                    if response == .alertSecondButtonReturn {
                        AppDelegate.shared.showSettings(nil)
                        AppDelegate.shared.settingsWindow?.select(pane: "文献库")
                    }
                }
            }
        })
    }

    // MARK: Targets

    override var targetItemIds: [String] {
        let selected = model.selectedItemIDs
        guard !selected.isEmpty else { return [] }
        // Display order, so batch commands (copy citations) keep the list order.
        return model.rows.filter(selected.contains) + selected.subtracting(model.rows).sorted()
    }

    override var targetFileId: String? {
        model.selectedItemIDs.isEmpty && model.selectedFileIDs.count == 1 ? model.selectedFileIDs.first : nil
    }

    override func quickLook() {
        splitViewController.itemList.controller.toggleQuickLook()
    }

    override func editNote(itemId: String) {
        if !model.selectedItemIDs.contains(itemId) {
            model.selectedItemIDs = [itemId]
            model.selectedFileIDs = []
        }
        model.inspectorTab = .notes
        splitViewController.showInspector()
        model.noteFocusRequest += 1
    }

    // MARK: Sheets

    /// Presents `activeSheet` as a window sheet, and closes it when the model clears it.
    private func syncSheet(_ sheet: AppModel.ActiveSheet?) {
        if let presented = presentedSheet {
            guard sheet == nil else { return }
            presentedSheet = nil
            presented.presentingViewController?.dismiss(presented)
            return
        }
        guard let sheet else { return }
        let dismiss = SheetDismissAction { [weak self] in self?.model.activeSheet = nil }
        let content: AnyView = switch sheet {
        case .identifierAdd: AnyView(IdentifierAddSheet(model: model))
        case .manualMatch(let id): AnyView(ManualMatchSheet(model: model, itemId: id))
        case .zoteroImport: AnyView(ZoteroImportSheet(model: model))
        case let .tagEditor(tagId, applyTo, initialName):
            AnyView(TagEditorSheet(model: model, tagId: tagId, applyTo: applyTo, initialName: initialName))
        case .translate(let fileId): AnyView(TranslateSheet(model: model, fileId: fileId))
        }
        let host = NSHostingController(rootView: content.environment(\.sheetDismiss, dismiss))
        host.sizingOptions = [.preferredContentSize]
        presentedSheet = host
        // Sheets belong to the window the user is looking at: a reader tab or this window.
        let presenter = (NSApp.keyWindow?.windowController as? FolioWindowController)?.window?.contentViewController
            ?? window?.contentViewController
        presenter?.presentAsSheet(host)
    }

    // MARK: NSWindowDelegate

    /// The library is the anchor tab: while papers are open next to it, it stays (UI-09).
    /// Alone, it closes like any main window and comes back from the Dock or 窗口 ▸ 文献库.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard (sender.tabGroup?.windows.count ?? 1) > 1 else { return true }
        NSSound.beep()
        model.toasts.show("文献库标签不能关闭，可以关闭论文标签", systemImage: "books.vertical")
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Quick Look follows the list; it should not outlive the window.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
    }

    // MARK: Search (SEARCH-01)

    private func focusSearchField() {
        if let searchItem {
            searchItem.beginSearchInteraction()
        } else {
            window?.toolbar?.isVisible = true
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        model.search.text = field.stringValue
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        model.search.text = ""
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Return / ↓ moves into the results, like Mail.
        if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.moveDown(_:)) {
            splitViewController.itemList.focusList()
            return true
        }
        return false
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The flexible space before the sidebar button pins it to the sidebar's trailing edge; when the
        // sidebar collapses, AppKit moves it next to the window controls.
        [.flexibleSpace, .toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .folioAdd, .space, .folioRead,
         .folioTranslate, .folioExport, .space, .folioSearch, .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.folioNote, .folioReveal, .folioRetrieve, .space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .folioAdd:
            let menu = NSMenu()
            menu.addItem(withTitle: "添加文件…", action: #selector(addFiles(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "通过标识符添加…", action: #selector(addByIdentifier(_:)), keyEquivalent: "")
            menu.items[0].image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            menu.items[1].image = NSImage(systemSymbolName: "number", accessibilityDescription: nil)
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = menu
            item.showsIndicator = false
            item.action = #selector(addFiles(_:))
            return configure(item, label: "添加", symbol: "plus", tip: "添加文献（按住可选择添加方式）")
        case .folioRead:
            let item = NSToolbarItem(itemIdentifier: id)
            item.action = #selector(openInReader(_:))
            return configure(item, label: "阅读", symbol: "book.pages", tip: "在 Folio 中阅读所选文献")
        case .folioTranslate:
            let item = NSToolbarItem(itemIdentifier: id)
            item.action = #selector(translateDocument(_:))
            return configure(item, label: "翻译", symbol: "character.book.closed", tip: "保留排版翻译全文")
        case .folioExport:
            let menu = NSMenu()
            let export = menu.addItem(withTitle: "导出参考文献…", action: #selector(exportBibTeX(_:)), keyEquivalent: "")
            export.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            menu.addItem(.separator())
            for (index, style) in CitationStyleOption.allCases.enumerated() {
                let item = menu.addItem(withTitle: "拷贝 \(style.title) 引用", action: #selector(copyCitation(_:)), keyEquivalent: "")
                item.tag = index
            }
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.menu = menu
            item.showsIndicator = false
            return configure(item, label: "导出", symbol: "square.and.arrow.up", tip: "导出 BibTeX 或拷贝引用")
        case .folioSearch:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.label = "搜索"
            item.paletteLabel = "搜索"
            item.searchField.placeholderString = "搜索文献"
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.setAccessibilityIdentifier("searchField")
            item.preferredWidthForSearchField = 180
            // The field would otherwise stretch over all free toolbar space.
            item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            searchItem = item
            return item
        case .folioNote:
            let item = NSToolbarItem(itemIdentifier: id)
            item.action = #selector(editNote(_:))
            return configure(item, label: "笔记", symbol: "note.text", tip: "编辑所选条目的笔记")
        case .folioReveal:
            let item = NSToolbarItem(itemIdentifier: id)
            item.action = #selector(revealInFinder(_:))
            return configure(item, label: "在 Finder 中显示", symbol: "folder", tip: "在 Finder 中显示")
        case .folioRetrieve:
            let item = NSToolbarItem(itemIdentifier: id)
            item.action = #selector(retrieveMetadata(_:))
            return configure(item, label: "检索元数据", symbol: "arrow.clockwise", tip: "重新检索元数据")
        default:
            return nil
        }
    }

    private func configure(_ item: NSToolbarItem, label: String, symbol: String, tip: String) -> NSToolbarItem {
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = nil
        return item
    }

    // MARK: Library actions

    @objc func addFiles(_ sender: Any?) { model.chooseFilesToImport() }
    @objc func addByIdentifier(_ sender: Any?) { model.activeSheet = .identifierAdd }
    @objc func newGroup(_ sender: Any?) { model.createGroup() }
    @objc func newSubgroup(_ sender: Any?) {
        if case .group(let id) = model.sidebarSelection {
            model.createGroup(parentId: model.snapshot.groupsById[id]?.parentId ?? id)
        }
    }
    @objc func newTag(_ sender: Any?) { model.activeSheet = .tagEditor(tagId: nil, applyTo: targetItemIds) }
    @objc func importFromZotero(_ sender: Any?) { model.activeSheet = .zoteroImport }
    @objc func importReferences(_ sender: Any?) { model.chooseReferencesToImport() }
    @objc func focusSearch(_ sender: Any?) { model.showSearch() }
    @objc func moveToTrash(_ sender: Any?) { model.deleteSelection(command: true) }
    @objc func removeFromGroup(_ sender: Any?) { model.removeFromCurrentGroup(targetItemIds) }
    @objc func restoreFromTrash(_ sender: Any?) { model.restoreItems(targetItemIds) }
    @objc func deletePermanently(_ sender: Any?) { model.confirmPurge(targetItemIds) }
    @objc func emptyTrash(_ sender: Any?) { model.confirmEmptyTrash() }
    @objc func sortManually(_ sender: Any?) { model.setSort(.manual) }

    /// Standard Edit ▸ Delete: same as ⌫ in the list (TRASH-02).
    @objc func delete(_ sender: Any?) { model.deleteSelection(command: false) }

    @objc func showInspectorTab(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, InspectorTab.allCases.indices.contains(item.tag) else { return }
        model.inspectorTab = InspectorTab.allCases[item.tag]
        splitViewController.showInspector()
    }

    @objc func setReadStatusFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let status = ReadStatus(rawValue: item.tag) else { return }
        model.setReadStatus(status, on: targetItemIds)
    }

    @objc func setRatingFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        model.setRating(item.tag, on: targetItemIds)
    }

    @objc func toggleSearchScope(_ sender: Any?) { model.search.wholeLibrary.toggle() }
    @objc func toggleFulltextSearch(_ sender: Any?) { model.search.includeFulltext.toggle() }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let ids = targetItemIds
        let items = ids.compactMap { model.snapshot.items[$0] }
        let inTrash = model.sidebarSelection == .trash
        switch menuItem.action {
        case #selector(moveToTrash(_:)):
            return (!ids.isEmpty || !model.selectedFileIDs.isEmpty) && !isEditingText
        case #selector(delete(_:)):
            return !ids.isEmpty || !model.selectedFileIDs.isEmpty
        case #selector(removeFromGroup(_:)):
            return model.isUserGroupSelected && !ids.isEmpty
        case #selector(restoreFromTrash(_:)), #selector(deletePermanently(_:)):
            return inTrash && !ids.isEmpty
        case #selector(emptyTrash(_:)):
            return (model.counts[.trash] ?? 0) > 0
        case #selector(newSubgroup(_:)):
            return model.isUserGroupSelected
        case #selector(sortManually(_:)):
            menuItem.state = model.currentSort == .manual ? .on : .off
            return model.currentSort != .manual && !model.search.isActive
        case #selector(showInspectorTab(_:)):
            menuItem.state = InspectorTab.allCases.firstIndex(of: model.inspectorTab) == menuItem.tag
                && !splitViewController.isInspectorCollapsed ? .on : .off
            return true
        case #selector(setReadStatusFromMenu(_:)):
            let regular = items.filter { $0.kind == .regular }
            menuItem.state = !regular.isEmpty && regular.allSatisfy { $0.readStatus.rawValue == menuItem.tag } ? .on : .off
            return !regular.isEmpty && !inTrash
        case #selector(setRatingFromMenu(_:)):
            menuItem.state = !items.isEmpty && items.allSatisfy { $0.rating == menuItem.tag } ? .on : .off
            return !items.isEmpty && !inTrash
        case #selector(toggleSearchScope(_:)):
            menuItem.state = model.search.wholeLibrary ? .on : .off
            return true
        case #selector(toggleFulltextSearch(_:)):
            menuItem.state = model.search.includeFulltext ? .on : .off
            return true
        default:
            return super.validateMenuItem(menuItem)
        }
    }
}

extension NSToolbarItem.Identifier {
    // Raw values are stored in users' saved toolbar layouts: never rename them.
    static let folioAdd = NSToolbarItem.Identifier("FolioAdd")
    static let folioRead = NSToolbarItem.Identifier("FolioRead")
    static let folioTranslate = NSToolbarItem.Identifier("FolioTranslate")
    static let folioExport = NSToolbarItem.Identifier("FolioExport")
    static let folioSearch = NSToolbarItem.Identifier("FolioSearch")
    static let folioNote = NSToolbarItem.Identifier("FolioNote")
    static let folioReveal = NSToolbarItem.Identifier("FolioReveal")
    static let folioRetrieve = NSToolbarItem.Identifier("FolioRetrieve")
}
