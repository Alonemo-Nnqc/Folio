import AppKit
import FolioCore
import Quartz

/// Row objects for the item outline, cached by id so NSOutlineView keeps expansion across reloads.
final class ItemNode: NSObject {
    let id: String
    init(id: String) { self.id = id }
}

final class FileNode: NSObject {
    let id: String
    let itemId: String
    init(id: String, itemId: String) {
        self.id = id
        self.itemId = itemId
    }
}

/// Outline subclass for keyboard shortcuts and Quick Look (LIST-08/09, TRASH-02).
final class ItemOutlineView: NSOutlineView {
    weak var controller: ItemListController?

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 36, 76: controller?.openSelection()                           // Return / Enter
        case 49: controller?.toggleQuickLook()                             // Space
        case 51, 117: controller?.model?.deleteSelection(command: command) // ⌫ / ⌦
        default: super.keyDown(with: event)
        }
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        controller?.model?.externalDropCount = 0
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        // No super call: NSOutlineView does not implement draggingEnded:, so super raises an
        // "unrecognized selector" exception inside AppKit's drag completion, which breaks every
        // later drag into this window.
        controller?.model?.externalDropCount = 0
        draggingDestinationFeedbackStyle = .gap
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = controller
            panel.delegate = controller
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}

final class ItemListController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let outline = ItemOutlineView()
    weak var model: AppModel?
    private var itemNodes: [String: ItemNode] = [:]
    private var fileNodes: [String: FileNode] = [:]
    private var rows: [ItemNode] = []
    private var lastRowIds: [String] = []
    private var lastFileLists: [String: [String]] = [:]
    private var lastExpandable: Set<String> = []
    private var expandedIds: Set<String> = []
    private var isApplyingModel = false
    private var lastSort: SortState?
    private var didInitialFit = false

    init(model: AppModel) {
        self.model = model
        super.init()
        configure()
    }

    // MARK: Setup

    private func configure() {
        outline.controller = self
        outline.dataSource = self
        outline.delegate = self
        outline.style = .inset
        outline.rowHeight = ItemListMetrics.rowHeight
        outline.intercellSpacing = NSSize(width: ItemListMetrics.columnSpacing, height: 0)
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.usesAlternatingRowBackgroundColors = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.indentationPerLevel = 18
        outline.autoresizesOutlineColumn = false
        outline.setAccessibilityIdentifier("itemList")

        for column in ItemColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.header
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minimumWidth
            tableColumn.resizingMask = column == .title ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            tableColumn.isHidden = !column.visibleByDefault
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            outline.addTableColumn(tableColumn)
            if column == .title { outline.outlineTableColumn = tableColumn }
        }
        // UI tests (`-FolioUITesting YES`) must not overwrite the user's column layout.
        if !UserDefaults.standard.bool(forKey: "FolioUITesting") {
            outline.autosaveName = "FolioItemColumns"
            outline.autosaveTableColumns = true
        }
        if let title = outline.tableColumn(withIdentifier: ItemColumn.title.identifier) { title.isHidden = false }

        let headerMenu = NSMenu()
        headerMenu.delegate = self
        headerMenu.identifier = NSUserInterfaceItemIdentifier("header")
        outline.headerView?.menu = headerMenu
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        rowMenu.autoenablesItems = false
        outline.menu = rowMenu

        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        // File URLs are accepted here directly (not via SwiftUI's onDrop): the outline sits on top of the
        // hosting view, so AppKit delivers Finder drags to it.
        outline.registerForDraggedTypes([.folioItem, .fileURL])
        outline.setDraggingSourceOperationMask([.copy, .link, .move, .delete], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.draggingDestinationFeedbackStyle = .gap
    }

    // MARK: Model → view

    func update() {
        guard let model else { return }
        let snapshot = model.snapshot
        let ids = model.rows
        let fileLists = Dictionary(uniqueKeysWithValues: ids.map { ($0, snapshot.filesByItem[$0] ?? []) })
        // A standalone file turning into an item keeps its id and file but gains a disclosure arrow.
        let expandable = Set(ids.filter { snapshot.items[$0]?.kind == .regular && !(fileLists[$0] ?? []).isEmpty })
        isApplyingModel = true
        defer { isApplyingModel = false }

        if ids != lastRowIds || fileLists != lastFileLists || expandable != lastExpandable {
            rows = ids.map(itemNode)
            lastRowIds = ids
            lastFileLists = fileLists
            lastExpandable = expandable
            outline.reloadData()
            for node in rows where expandedIds.contains(node.id) && !(fileLists[node.id] ?? []).isEmpty {
                outline.expandItem(node)
            }
        } else {
            reloadVisibleRows()
        }
        applySortIndicator(model.currentSort)
        if let id = model.previewExpandRequest, let node = itemNodes[id] {
            model.previewExpandRequest = nil
            outline.expandItem(node)
        }
        restoreSelection(items: model.selectedItemIDs, files: model.selectedFileIDs)
        fitColumnsOnce()
    }

    /// On first layout, make every visible column fit: the title column keeps at least 260 pt and
    /// the other columns shrink proportionally.
    private func fitColumnsOnce() {
        guard !didInitialFit, let clip = outline.enclosingScrollView?.contentView, clip.bounds.width > 100 else { return }
        didInitialFit = true
        let visible = outline.tableColumns.filter { !$0.isHidden }
        let spacing = outline.intercellSpacing.width * CGFloat(visible.count) + 24
        let available = clip.bounds.width - spacing
        guard visible.reduce(0, { $0 + $1.width }) > available,
              let title = visible.first(where: { $0.identifier == ItemColumn.title.identifier }) else { return }
        let others = visible.filter { $0 !== title }
        let othersWidth = others.reduce(0) { $0 + $1.width }
        let titleWidth = max(260, available - othersWidth)
        let scale = min(1, (available - titleWidth) / max(othersWidth, 1))
        for column in others { column.width = max(column.minWidth, floor(column.width * scale)) }
        title.width = max(title.minWidth, available - others.reduce(0) { $0 + $1.width })
    }

    private func reloadVisibleRows() {
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
                           columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
    }

    private func applySortIndicator(_ sort: SortState) {
        guard sort != lastSort else { return }
        lastSort = sort
        if let column = sort.column,
           let itemColumn = ItemColumn.allCases.first(where: { $0.sortColumn == column }) {
            outline.sortDescriptors = [NSSortDescriptor(key: itemColumn.rawValue, ascending: sort.ascending)]
        } else {
            outline.sortDescriptors = []
        }
    }

    private func restoreSelection(items: Set<String>, files: Set<String>) {
        var indexes = IndexSet()
        for id in items { let row = outline.row(forItem: itemNodes[id]); if row >= 0 { indexes.insert(row) } }
        for id in files { let row = outline.row(forItem: fileNodes[id]); if row >= 0 { indexes.insert(row) } }
        if indexes != outline.selectedRowIndexes { outline.selectRowIndexes(indexes, byExtendingSelection: false) }
    }

    private func itemNode(_ id: String) -> ItemNode {
        if let node = itemNodes[id] { return node }
        let node = ItemNode(id: id)
        itemNodes[id] = node
        return node
    }

    private func fileNode(_ id: String, itemId: String) -> FileNode {
        if let node = fileNodes[id], node.itemId == itemId { return node }
        let node = FileNode(id: id, itemId: itemId)
        fileNodes[id] = node
        return node
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? ItemNode { return model?.snapshot.filesByItem[node.id]?.count ?? 0 }
        return item == nil ? rows.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? ItemNode, let fileId = model?.snapshot.filesByItem[node.id]?[index] {
            return fileNode(fileId, itemId: node.id)
        }
        return rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ItemNode, let item = model?.snapshot.items[node.id] else { return false }
        return item.kind == .regular && !(model?.snapshot.filesByItem[node.id] ?? []).isEmpty
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? ItemNode { expandedIds.insert(node.id) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? ItemNode { expandedIds.remove(node.id) }
    }

    // MARK: Cells

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let model, let identifier = tableColumn?.identifier, let column = ItemColumn(rawValue: identifier.rawValue) else {
            return nil
        }
        let snapshot = model.snapshot
        if let fileNode = item as? FileNode {
            guard column == .title, let file = snapshot.files[fileNode.id] else { return nil }
            let cell = make(TitleCell.self, TitleCell.identifier)
            cell.configureFile(file, url: model.fileURL(file), isDefault: snapshot.items[fileNode.itemId]?.defaultFileId == file.id)
            return cell
        }
        guard let node = item as? ItemNode, let entry = snapshot.items[node.id] else { return nil }
        switch column {
        case .title:
            let cell = make(TitleCell.self, TitleCell.identifier)
            let origin = entry.originItemId.flatMap { snapshot.items[$0]?.title }
            let job = model.translations.jobs[entry.id]
            let translation = job.map { (stage: $0.stage, fraction: $0.fraction) }
            cell.configureItem(entry, fileURL: model.defaultFile(of: entry.id).map(model.fileURL), origin: origin,
                               hasNote: snapshot.notedItems.contains(entry.id), translation: translation)
            return cell
        case .tags:
            let cell = make(TagsCell.self, TagsCell.identifier)
            cell.chips.tags = snapshot.tags(of: entry.id)
            return cell
        case .readStatus:
            let cell = make(TextCell.self, TextCell.identifier)
            cell.configure(CellText.readStatus(entry))
            return cell
        case .rating:
            let cell = make(TextCell.self, TextCell.identifier)
            cell.configure(CellText.rating(entry.rating))
            return cell
        default:
            let cell = make(TextCell.self, TextCell.identifier)
            cell.configure(column.text(for: entry, snapshot: snapshot),
                           secondary: column == .dateAdded || column == .dateModified)
            return cell
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        outlineView.makeView(withIdentifier: Self.rowViewIdentifier, owner: nil) as? SelectionRowView
            ?? { let row = SelectionRowView(); row.identifier = Self.rowViewIdentifier; return row }()
    }

    private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("SelectionRow")

    private func make<T: NSTableCellView>(_ type: T.Type, _ identifier: NSUserInterfaceItemIdentifier) -> T {
        outline.makeView(withIdentifier: identifier, owner: nil) as? T ?? T(frame: .zero)
    }

    // MARK: Selection

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModel, let model else { return }
        var items = Set<String>(), files = Set<String>()
        for row in outline.selectedRowIndexes {
            switch outline.item(atRow: row) {
            case let node as ItemNode: items.insert(node.id)
            case let node as FileNode: files.insert(node.id)
            default: break
            }
        }
        model.selectedItemIDs = items
        model.selectedFileIDs = files
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    // MARK: Sorting (LIST-06)

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingModel, let model else { return }
        guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key,
              let column = ItemColumn(rawValue: key) else {
            model.setSort(.manual)
            return
        }
        let sort = SortState(column: column.sortColumn, ascending: descriptor.ascending)
        lastSort = sort
        model.setSort(sort)
    }

    // MARK: Opening

    @objc private func doubleClicked() {
        guard outline.clickedRow >= 0 else { return }
        // ⌥ double-click opens the paper in a background tab (READER-01).
        open(row: outline.clickedRow, inBackground: NSEvent.modifierFlags.contains(.option))
    }

    func openSelection() {
        for row in outline.selectedRowIndexes { open(row: row, inBackground: false) }
    }

    private func open(row: Int, inBackground: Bool) {
        guard let model else { return }
        switch outline.item(atRow: row) {
        case let node as ItemNode:
            if let file = model.defaultFile(of: node.id) {
                model.open(fileId: file.id, inBackground: inBackground)
            } else {
                model.open(itemId: node.id)
            }
        case let node as FileNode: model.open(fileId: node.id, inBackground: inBackground)
        default: break
        }
    }

    // MARK: Quick Look (LIST-09)

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    private var previewURLs: [URL] {
        guard let model else { return [] }
        return outline.selectedRowIndexes.compactMap { row -> URL? in
            switch outline.item(atRow: row) {
            case let node as ItemNode: model.defaultFile(of: node.id).map(model.fileURL)
            case let node as FileNode: model.snapshot.files[node.id].map(model.fileURL)
            default: nil
            }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 49 {
            panel.orderOut(nil)
            return true
        }
        return false
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        if menu.identifier?.rawValue == "header" {
            buildHeaderMenu(menu)
            return
        }
        let clicked = outline.clickedRow
        guard clicked >= 0 else { return }
        // Right-clicking outside the selection acts on the clicked row only.
        if !outline.selectedRowIndexes.contains(clicked) {
            outline.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        var context = ItemMenuContext(scope: model.sidebarSelection, itemIds: [], fileId: nil)
        if let file = outline.item(atRow: clicked) as? FileNode {
            context.fileId = file.id
        } else {
            context.itemIds = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ItemNode)?.id }
        }
        let fileId = context.fileId ?? (context.itemIds.count == 1 ? model.defaultFile(of: context.itemIds[0])?.id : nil)
        if let fileId, let file = model.snapshot.files[fileId] {
            context.openWithApps = FolioWindowController.apps(toOpen: model.fileURL(file))
        }
        context.translatingItemIds = model.translations.activeItemIds
        let entries = ItemMenuBuilder.entries(for: context, snapshot: model.snapshot, groups: model.groupsForMenus)
        ItemMenuBuilder.populate(menu, with: entries, snapshot: model.snapshot) { [weak self] command in
            (self?.outline.window?.windowController as? FolioWindowController)?.perform(command, context: context)
        }
    }

    private func buildHeaderMenu(_ menu: NSMenu) {
        for column in ItemColumn.allCases where column != .title {
            guard let tableColumn = outline.tableColumn(withIdentifier: column.identifier) else { continue }
            let item = NSMenuItem.closure(column.header) { [weak tableColumn] in
                tableColumn?.isHidden.toggle()
            }
            item.state = tableColumn.isHidden ? .off : .on
            menu.addItem(item)
        }
    }

    // MARK: Drag source (DND-03/06)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let model else { return nil }
        switch item {
        case let node as ItemNode:
            let url = model.defaultFile(of: node.id).map(model.fileURL)
            return ItemPasteboard.writer(itemId: node.id, scope: model.sidebarSelection, fileURL: url)
        case let node as FileNode:
            return model.snapshot.files[node.id].map { model.fileURL($0) as NSURL }
        default:
            return nil
        }
    }

    // MARK: Drop target: reordering (DND-04) and files from Finder (DND-01)

    private func dropDecision(_ info: any NSDraggingInfo) -> ListDropDecision {
        guard let model else { return .reject }
        return ListDropRules.decide(hasFolioItems: !ItemPasteboard.draggedItems(info.draggingPasteboard).isEmpty,
                                    fromThisList: info.draggingSource as? NSOutlineView === outline,
                                    fileCount: ItemPasteboard.fileURLs(info.draggingPasteboard).count,
                                    isSearching: model.search.isActive, scope: model.sidebarSelection)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let model else { return [] }
        switch dropDecision(info) {
        case .reject:
            model.externalDropCount = 0
            return []
        case .importFiles:
            // The whole list is the target; the glass overlay replaces the table's own highlight.
            outlineView.draggingDestinationFeedbackStyle = .none
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            let count = ItemPasteboard.fileURLs(info.draggingPasteboard).count
            if model.externalDropCount != count { model.externalDropCount = count }
            return .copy
        case .reorder:
            outlineView.draggingDestinationFeedbackStyle = .gap
        }
        var target = index
        if let node = item as? ItemNode {
            // Dropping on or inside an item: retarget to the gap above it.
            target = rows.firstIndex(of: node) ?? rows.count
        } else if item is FileNode {
            return []
        }
        if item != nil || index == NSOutlineViewDropOnItemIndex {
            outlineView.setDropItem(nil, dropChildIndex: max(target, 0))
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let model else { return false }
        if dropDecision(info) == .importFiles {
            model.externalDropCount = 0
            model.importer.importFiles(ItemPasteboard.fileURLs(info.draggingPasteboard), toGroup: model.sidebarSelection.groupId)
            return true
        }
        let ids = ItemPasteboard.draggedItems(info.draggingPasteboard).map(\.itemId)
        guard !ids.isEmpty else { return false }
        model.moveItems(ids, toIndex: index < 0 ? rows.count : index)
        return true
    }
}
