import AppKit
import FolioCore
import Quartz

/// Row objects for the item outline, cached by id so NSOutlineView keeps expansion across reloads.
final class ItemNode: NSObject {
    let id: String
    init(id: String) { self.id = id }
}

/// An item's note, listed under the item like one of its documents (open it, export it).
final class NoteNode: NSObject {
    let itemId: String
    init(itemId: String) { self.itemId = itemId }
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

    /// 多选: a plain click adds the row to the selection or takes it out (the disclosure triangle still opens the row).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if controller?.model?.multiSelectMode == true, event.clickCount == 1, row >= 0,
           event.modifierFlags.intersection([.command, .shift]).isEmpty, !frameOfOutlineCell(atRow: row).contains(point) {
            window?.makeFirstResponder(self)
            if selectedRowIndexes.contains(row) {
                deselectRow(row)
            } else {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 53, controller?.model?.multiSelectMode == true {   // Esc leaves 多选
            controller?.model?.multiSelectMode = false
            return
        }
        switch event.keyCode {
        case 36, 76: controller?.openSelection()                           // Return / Enter
        case 49: controller?.toggleQuickLook()                             // Space
        case 51, 117: controller?.model?.deleteSelection(command: command) // ⌫ / ⌦
        default: super.keyDown(with: event)
        }
    }

    /// Three-finger tap or force click (系统设置 ▸ 触控板 ▸ 查询与数据检测器): Quick Look the row under the
    /// pointer, as in Finder. On another row while the panel is open, the panel follows the new selection.
    override func quickLook(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return super.quickLook(with: event) }
        window?.makeFirstResponder(self)
        if selectedRowIndexes.contains(row) {
            controller?.toggleQuickLook()
            return
        }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if !(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) {
            controller?.toggleQuickLook()
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
    QLPreviewPanelDataSource, QLPreviewPanelDelegate, NSTextFieldDelegate {
    let outline = ItemOutlineView()
    weak var model: AppModel?
    private var itemNodes: [String: ItemNode] = [:]
    private var fileNodes: [String: FileNode] = [:]
    private var noteNodes: [String: NoteNode] = [:]
    /// The note row chosen: the item is the selection, its note row is the row shown selected.
    private var selectedNoteItemId: String?
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
        // The columns always span the list's width: `fitColumns` keeps them so when the list changes width (in the
        // same layout pass); while a column edge is dragged AppKit takes the width from the columns to its right (the
        // far ones first, as in Finder), in the same pass as the drag: no correction afterwards that would flash.
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        let header = ItemHeaderView()
        header.onDrag = { [weak self] dragging in self?.columnDrag(dragging) }
        header.frame = outline.headerView?.frame ?? NSRect(x: 0, y: 0, width: 100, height: 28)
        outline.headerView = header
        outline.indentationPerLevel = 18
        outline.autoresizesOutlineColumn = false
        outline.setAccessibilityIdentifier("itemList")

        // 出版物 right after the title; the rest in their declared order.
        for column in [ItemColumn.title, .venue] + ItemColumn.allCases.filter({ $0 != .title && $0 != .venue }) {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.header
            tableColumn.width = column.defaultWidth
            tableColumn.minWidth = column.minimumWidth
            tableColumn.headerCell = ItemHeaderCell(textCell: column.header)
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
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
        // Reloading the rows would end the rename.
        guard let model, renaming == nil else { return }
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

    /// The progress of running translations, in the rows showing them.
    func updateTranslationProgress(_ jobs: [String: TranslationCoordinator.JobState]) {
        let column = outline.column(withIdentifier: ItemColumn.title.identifier)
        guard column >= 0 else { return }
        for (id, job) in jobs {
            guard let node = itemNodes[id] else { continue }
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: column, row: row, makeIfNecessary: false) as? TitleCell else { continue }
            cell.updateTranslation(stage: job.stage, fraction: job.fraction)
        }
    }

    /// On first layout, make every visible column fit.
    private func fitColumnsOnce() {
        guard !didInitialFit else { return }
        if let clip = outline.enclosingScrollView?.contentView, !observesClip {
            observesClip = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fitColumns() }
            }
            NotificationCenter.default.addObserver(forName: NSTableView.columnDidMoveNotification, object: outline, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLastColumn() }
            }
        }
        fitColumns()
    }

    private var observesClip = false
    private var isFitting = false
    /// The width each column would like: what it was dragged to, else its saved or default width. A list squeezed
    /// for a while (a narrow window) gives every column its width back when it widens again.
    private var preferred: [NSUserInterfaceItemIdentifier: CGFloat] = [:]

    /// A column edge dragged in the header: AppKit resizes the columns on its right while the mouse moves; what
    /// the columns end at becomes what they would like.
    private func columnDrag(_ dragging: Bool) {
        if dragging {
            for column in visibleColumns { column.minWidth = minimum(column) }
            outline.columnAutoresizingStyle = .sequentialColumnAutoresizingStyle
        } else {
            outline.columnAutoresizingStyle = .noColumnAutoresizing
            for column in visibleColumns { preferred[column.identifier] = column.width }
            fitColumns()
        }
    }

    private var visibleColumns: [NSTableColumn] { outline.tableColumns.filter { !$0.isHidden } }

    private func minimum(_ column: NSTableColumn) -> CGFloat {
        ItemColumn(rawValue: column.identifier.rawValue)?.minimumWidth ?? 44
    }

    /// The width the visible columns share: the list's width less its side insets and the gaps between columns.
    private var availableWidth: CGFloat? {
        guard let clip = outline.enclosingScrollView?.contentView, clip.bounds.width > 100 else { return nil }
        let visible = visibleColumns
        guard let first = visible.first, let index = outline.tableColumns.firstIndex(of: first) else { return nil }
        // The inset style's padding on each side (where the first column starts).
        let lead = max(outline.rect(ofColumn: index).minX, 0)
        return floor(clip.bounds.width - lead * 2 - outline.intercellSpacing.width * CGFloat(visible.count))
    }

    /// Makes the visible columns span exactly `width` (the list's width), starting from the widths they would like:
    /// room to spare goes to the title; room missing comes from the title down to a comfortable width, then from
    /// every column in proportion down to its minimum, then (on a very narrow list) below it.
    func fitColumns(to width: CGFloat? = nil) {
        guard !isFitting, let available = width ?? availableWidth else { return }
        didInitialFit = true
        isFitting = true
        defer { isFitting = false; updateLastColumn() }
        let visible = visibleColumns
        guard !visible.isEmpty else { return }
        let title = visible.first { $0.identifier == ItemColumn.title.identifier } ?? visible[0]
        for column in visible where preferred[column.identifier] == nil {
            preferred[column.identifier] = max(column.width, minimum(column))
        }
        var widths = visible.map { floor(preferred[$0.identifier] ?? $0.width) }
        var delta = available - widths.reduce(0, +)
        let t = visible.firstIndex { $0 === title }!
        if delta > 0 {
            widths[t] += delta
        } else if delta < 0 {
            let comfortable = max(minimum(title), min(260, available * 0.35))
            let fromTitle = min(-delta, max(widths[t] - comfortable, 0))
            widths[t] -= fromTitle
            delta += fromTitle
            if delta < 0 {
                let spare = visible.indices.map { max(widths[$0] - minimum(visible[$0]), 0) }
                let total = spare.reduce(0, +)
                if total > 0 {
                    let take = min(-delta, total)
                    for k in visible.indices { widths[k] -= floor(take * spare[k] / total) }
                    delta = available - widths.reduce(0, +)
                }
            }
            if delta < 0 {
                let sum = widths.reduce(0, +)
                let scale = max(available, CGFloat(visible.count) * 28) / sum
                widths = widths.map { max(28, floor($0 * scale)) }
            }
            widths[t] += available - widths.reduce(0, +)
            widths[t] = max(widths[t], 28)
        }
        for (k, column) in visible.enumerated() {
            // A column squeezed under its minimum gets a lower one for now (AppKit would refuse the width).
            column.minWidth = min(minimum(column), widths[k])
            if abs(column.width - widths[k]) >= 0.5 { column.width = widths[k] }
        }
    }

    /// The last column's right edge is the list's edge: it cannot be dragged, and no rule is drawn there.
    private func updateLastColumn() {
        let visible = visibleColumns
        for column in outline.tableColumns {
            let last = column === visible.last
            column.resizingMask = last ? [.autoresizingMask] : [.autoresizingMask, .userResizingMask]
            (column.headerCell as? ItemHeaderCell)?.isLast = last
        }
        outline.headerView?.needsDisplay = true
    }

    // MARK: Renaming a Markdown document (MD-01)

    private var renaming: (fileId: String, field: NSTextField, name: String)?
    private var cancelsRename = false

    /// The document's name edited in its row. False when it has none on screen.
    func beginRenaming(fileId: String) -> Bool {
        guard let model, let file = model.snapshot.files[fileId], file.isMarkdown, outline.window?.isKeyWindow == true else { return false }
        let own = model.snapshot.items[file.itemId]?.kind == .standalone
        let row = own ? outline.row(forItem: itemNodes[file.itemId]) : outline.row(forItem: fileNodes[fileId])
        guard row >= 0 else { return false }
        outline.scrollRowToVisible(row)
        let column = outline.column(withIdentifier: ItemColumn.title.identifier)
        guard let cell = outline.view(atColumn: column, row: row, makeIfNecessary: true) as? TitleCell else { return false }
        let name = model.snapshot.documentName(file)
        renaming = (fileId, cell.label, name)
        cancelsRename = false
        cell.label.stringValue = name
        cell.label.isEditable = true
        cell.label.delegate = self
        guard outline.window?.makeFirstResponder(cell.label) == true else {
            endRenaming()
            return false
        }
        cell.label.currentEditor()?.selectAll(nil)
        return true
    }

    private func endRenaming() {
        guard let (_, field, _) = renaming else { return }
        renaming = nil
        field.isEditable = false
        field.delegate = nil
        lastRowIds = []
        update()
        outline.window?.makeFirstResponder(outline)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let (fileId, field, name) = renaming, obj.object as? NSTextField === field else { return }
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cancelsRename, !typed.isEmpty, typed != name { model?.renameMarkdownFile(fileId, to: typed) }
        DispatchQueue.main.async { [weak self] in self?.endRenaming() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard renaming != nil, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelsRename = true
        control.window?.makeFirstResponder(outline)
        return true
    }

    /// The ring of a paper in its row (设置 ▸ 通用 ▸ 在列表中显示阅读进度环). Choosing rows shows check circles instead.
    private func showRing(of item: Item, in cell: TitleCell) {
        guard let model else { return }
        let shown = model.settings.showReadingRings && !model.multiSelectMode && !item.isTrashed
        let status = shown && model.snapshot.tracksReading(item) ? item.readStatus : nil
        cell.showRing(status, fraction: model.readingProgress[item.id]?.fraction ?? 0, room: shown) { [weak model] in
            model?.setReadStatus($0, on: [item.id])
        }
    }

    /// The rings on screen, after a paper was read further (no row is reloaded).
    func updateReadingProgress() {
        guard let model else { return }
        let title = outline.column(withIdentifier: ItemColumn.title.identifier)
        let status = outline.column(withIdentifier: ItemColumn.readStatus.identifier)
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<visible.location + visible.length {
            guard let node = outline.item(atRow: row) as? ItemNode, let item = model.snapshot.items[node.id], item.readStatus == .reading else { continue }
            if title >= 0, let cell = outline.view(atColumn: title, row: row, makeIfNecessary: false) as? TitleCell { showRing(of: item, in: cell) }
            if status >= 0, let cell = outline.view(atColumn: status, row: row, makeIfNecessary: false) as? TextCell {
                cell.configure(CellText.readStatus(.reading, fraction: model.readingProgress[item.id]?.fraction ?? 0))
            }
        }
    }

    /// The check circles of the rows on screen, after the selection changed (多选).
    func updateChecks() {
        guard let model else { return }
        let column = outline.column(withIdentifier: ItemColumn.title.identifier)
        let visible = outline.rows(in: outline.visibleRect)
        guard column >= 0, visible.length > 0 else { return }
        for row in visible.location..<visible.location + visible.length {
            guard let node = outline.item(atRow: row) as? ItemNode,
                  let cell = outline.view(atColumn: column, row: row, makeIfNecessary: false) as? TitleCell else { continue }
            cell.showCheck(model.selectedItemIDs.contains(node.id))
        }
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
        defer { outline.headerView?.needsDisplay = true }
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
        if let noted = selectedNoteItemId, files.isEmpty, items == [noted], let node = noteNodes[noted] {
            let row = outline.row(forItem: node)
            if row >= 0 { indexes = [row] }
        }
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

    private func noteNode(_ itemId: String) -> NoteNode {
        if let node = noteNodes[itemId] { return node }
        let node = NoteNode(itemId: itemId)
        noteNodes[itemId] = node
        return node
    }

    // MARK: Data source

    /// The files listed under an item (a standalone file is the item itself).
    private func childFiles(_ itemId: String) -> [String] {
        guard let model, model.snapshot.items[itemId]?.kind == .regular else { return [] }
        return model.snapshot.filesByItem[itemId] ?? []
    }

    private func hasNote(_ itemId: String) -> Bool { model?.snapshot.notedItems.contains(itemId) ?? false }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? ItemNode { return childFiles(node.id).count + (hasNote(node.id) ? 1 : 0) }
        return item == nil ? rows.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? ItemNode {
            let files = childFiles(node.id)
            return index < files.count ? fileNode(files[index], itemId: node.id) : noteNode(node.id)
        }
        return rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? ItemNode else { return false }
        return !childFiles(node.id).isEmpty || hasNote(node.id)
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
        if let note = item as? NoteNode {
            guard column == .title else { return nil }
            let cell = make(TitleCell.self, TitleCell.identifier)
            cell.configureNote(preview: Self.notePreview(model, itemId: note.itemId))
            return cell
        }
        if let fileNode = item as? FileNode {
            guard column == .title, let file = snapshot.files[fileNode.id] else { return nil }
            let cell = make(TitleCell.self, TitleCell.identifier)
            cell.configureFile(file, label: model.label(of: file), url: model.fileURL(file),
                               isDefault: snapshot.items[fileNode.itemId]?.defaultFileId == file.id)
            return cell
        }
        guard let node = item as? ItemNode, let entry = snapshot.items[node.id] else { return nil }
        switch column {
        case .title:
            let cell = make(TitleCell.self, TitleCell.identifier)
            let origin = entry.originItemId.flatMap { snapshot.items[$0]?.title }
            let job = model.translations.currentJob(of: entry.id)
            let translation = job.map { (stage: $0.stage, fraction: $0.fraction) }
            // 设置 ▸ 通用 ▸ 显示“已翻译”标签 off: no badge (the files are still listed under the paper).
            let translations = model.settings.showTranslatedBadge
                ? snapshot.files(of: entry.id).filter { $0.translationKind != nil }.map(model.label(of:)) : []
            cell.configureItem(entry, fileURL: model.defaultFile(of: entry.id).map(model.fileURL), origin: origin,
                               hasNote: snapshot.notedItems.contains(entry.id), translation: translation,
                               translations: translations)
            showRing(of: entry, in: cell)
            cell.showCheck(model.multiSelectMode ? model.selectedItemIDs.contains(entry.id) : nil)
            return cell
        case .tags:
            let cell = make(TagsCell.self, TagsCell.identifier)
            cell.chips.tags = snapshot.tags(of: entry.id)
            return cell
        case .readStatus:
            let cell = make(TextCell.self, TextCell.identifier)
            cell.configure(snapshot.tracksReading(entry)
                ? CellText.readStatus(entry.readStatus, fraction: model.readingProgress[entry.id]?.fraction ?? 0) : NSAttributedString(string: ""))
            return cell
        case .rating:
            let cell = make(TextCell.self, TextCell.identifier)
            cell.configure(CellText.rating(entry.rating))
            return cell
        case .journalRank:
            let cell = make(JournalRankCell.self, JournalRankCell.identifier)
            cell.configure(snapshot.journalMetrics(for: entry))
            return cell
        case .venue:
            let cell = make(VenueCell.self, VenueCell.identifier)
            cell.badges.configure(venue: VenueCatalog.venue(of: entry), metrics: snapshot.journalMetrics(for: entry))
            return cell
        case .impactFactor:
            let cell = make(TextCell.self, TextCell.identifier)
            cell.configure(CellText.impactFactor(snapshot.journalMetrics(for: entry)?.impactFactor))
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
        var note: String?
        for row in outline.selectedRowIndexes {
            switch outline.item(atRow: row) {
            case let node as ItemNode: items.insert(node.id)
            case let node as FileNode: files.insert(node.id)
            case let node as NoteNode:
                items.insert(node.itemId)
                note = node.itemId
            default: break
            }
        }
        selectedNoteItemId = outline.selectedRowIndexes.count == 1 ? note : nil
        // The note row shows the note in the inspector.
        if selectedNoteItemId != nil { model.inspectorTab = .notes }
        model.selectedItemIDs = items
        model.selectedFileIDs = files
        if model.multiSelectMode { updateChecks() }
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
        case let node as NoteNode: model.openNote(itemId: node.itemId)
        default: break
        }
    }

    /// The first words of a note, after 笔记 in its row.
    static func notePreview(_ model: AppModel, itemId: String) -> String {
        let text = (try? model.library.note(for: itemId)) ?? ""
        let line = text.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.replacingOccurrences(of: #"^(#+|[-*+>]|\d+[.)]|- \[[ xX]\])\s*"#, with: "", options: .regularExpression).prefix(60))
    }

    // MARK: Quick Look (LIST-09)

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    /// Markdown (documents and notes) is set as in the editor: the system would show its bare text, if anything.
    private var previewItems: [any QLPreviewItem] {
        guard let model else { return [] }
        func note(_ itemId: String) -> (any QLPreviewItem)? {
            guard let text = try? model.library.note(for: itemId), !text.isEmpty else { return nil }
            let title = model.snapshot.items[itemId]?.title ?? ""
            return MarkdownPreviewItem.item(key: "note-\(itemId)", title: String(localized: "笔记：\(title)"), text: text, base: nil)
        }
        func document(_ file: FileRecord) -> any QLPreviewItem {
            let url = model.fileURL(file)
            if file.isMarkdown, let text = try? String(contentsOf: url, encoding: .utf8),
               let item = MarkdownPreviewItem.item(key: file.id, title: file.fileName, text: text, base: url.deletingLastPathComponent()) { return item }
            return url as NSURL
        }
        return outline.selectedRowIndexes.compactMap { row in
            switch outline.item(atRow: row) {
            case let node as ItemNode: model.defaultFile(of: node.id).map(document) ?? note(node.id)
            case let node as FileNode: model.snapshot.files[node.id].map(document)
            case let node as NoteNode: note(node.itemId)
            default: nil
            }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let items = previewItems
        return items.indices.contains(index) ? items[index] : nil
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
        guard clicked >= 0 else {
            buildBlankMenu(menu, trash: model.sidebarSelection == .trash)
            return
        }
        if let note = outline.item(atRow: clicked) as? NoteNode {
            outline.selectRowIndexes([clicked], byExtendingSelection: false)
            let itemId = note.itemId
            let open = NSMenuItem.closure(String(localized: "在标签页中打开")) { [weak model] in model?.openNote(itemId: itemId) }
            open.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            let export = NSMenuItem.closure(String(localized: "导出笔记…")) { [weak model] in model?.exportNote(itemId: itemId) }
            export.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            menu.addItem(open)
            menu.addItem(export)
            return
        }
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

    /// The list's empty space: what can be added here (as the 添加 button and the 文件 menu offer), and selecting.
    private func buildBlankMenu(_ menu: NSMenu, trash: Bool) {
        outline.deselectAll(nil)
        func add(_ title: String, _ action: Selector, _ symbol: String?) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }
        if trash {
            add(String(localized: "清空回收站…"), #selector(LibraryWindowController.emptyTrash(_:)), "trash")
            return
        }
        add(String(localized: "添加文件…"), #selector(LibraryWindowController.addFiles(_:)), "doc.badge.plus")
        add(String(localized: "通过标识符添加…"), #selector(LibraryWindowController.addByIdentifier(_:)), "number")
        add(String(localized: "新建 Markdown 文档"), #selector(LibraryWindowController.newMarkdownDocument(_:)), "doc.richtext")
        menu.addItem(.separator())
        add(String(localized: "新建分组"), #selector(LibraryWindowController.newGroup(_:)), "folder.badge.plus")
        add(String(localized: "新建标签…"), #selector(LibraryWindowController.newTag(_:)), "tag")
        menu.addItem(.separator())
        add(String(localized: "导入 BibTeX / RIS…"), #selector(LibraryWindowController.importReferences(_:)), "square.and.arrow.down")
        add(String(localized: "从 Zotero 导入…"), #selector(LibraryWindowController.importFromZotero(_:)), "books.vertical")
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.closure(String(localized: "全选")) { [weak self] in self?.outline.selectAll(nil) })
        add(String(localized: "多选"), #selector(LibraryWindowController.toggleMultiSelect(_:)), "checklist")
    }

    private func buildHeaderMenu(_ menu: NSMenu) {
        for column in ItemColumn.allCases where column != .title {
            guard let tableColumn = outline.tableColumn(withIdentifier: column.identifier) else { continue }
            let item = NSMenuItem.closure(column.header) { [weak self, weak tableColumn] in
                tableColumn?.isHidden.toggle()
                // A column shown makes room for itself from the others instead of running past the edge.
                if tableColumn?.isHidden == false, let tableColumn, let self, let available = self.availableWidth {
                    tableColumn.width = min(tableColumn.width, max(available * 0.3, self.minimum(tableColumn)))
                    self.preferred[tableColumn.identifier] = tableColumn.width
                }
                self?.fitColumns()
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
            let urls = ItemPasteboard.fileURLs(info.draggingPasteboard)
            if model.externalDropCount != urls.count {
                model.externalDropHasFolders = urls.contains(where: ImportCoordinator.isFolder)
                model.externalDropCount = urls.count
            }
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
