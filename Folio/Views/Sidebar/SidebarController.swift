import AppKit
import FolioCore

/// NSOutlineView subclass: hides the built-in disclosure triangle (groups use a trailing chevron)
/// and handles Return / Delete for groups.
final class SidebarOutlineView: NSOutlineView {
    var onRename: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isDelete = event.keyCode == 51 || event.keyCode == 117
        if selectedRow >= 0 && isReturn {
            onRename?(selectedRow)
        } else if selectedRow >= 0 && isDelete {
            onDelete?(selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Data source, delegate, menus and drag-and-drop for the sidebar (SIDE-*).
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let outline = SidebarOutlineView()
    private let tree = SidebarTree()
    private weak var model: AppModel?
    private var isSyncingSelection = false
    private var renamingGroupId: String?
    private static let expandedKey = "sidebarExpandedGroups"
    private static let tagsCollapsedKey = "sidebarTagsCollapsed"

    init(model: AppModel) {
        self.model = model
        super.init()
        configureOutline()
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.rowHeight = 28
        outline.indentationPerLevel = 16
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([.folioItem, .folioGroup, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList
        outline.setAccessibilityIdentifier("sidebar")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.onRename = { [weak self] row in self?.beginRenaming(row: row) }
        outline.onDelete = { [weak self] row in
            if let id = (self?.outline.item(atRow: row) as? SidebarNode)?.groupId { self?.model?.confirmDeleteGroup(id) }
        }
    }

    // MARK: Updates from the model

    func update() {
        // Reloading rows would reconfigure the cell being edited and end the rename.
        guard let model, renamingGroupId == nil else { return }
        let structureChanged = tree.rebuild(from: model.snapshot)
        if structureChanged {
            outline.reloadData()
            restoreExpansion()
        } else {
            let visible = outline.rows(in: outline.visibleRect)
            outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
                               columnIndexes: [0])
        }
        syncSelection()
        if let pending = model.groupPendingRename, let node = tree.node(for: .group(pending)) {
            model.groupPendingRename = nil
            expandAncestors(of: node)
            let row = outline.row(forItem: node)
            if row >= 0 {
                DispatchQueue.main.async { self.beginRenaming(row: row) }
            }
        }
    }

    private func syncSelection() {
        guard let model else { return }
        let kind: SidebarNode.Kind = switch model.sidebarSelection {
        case .all, .unfiled, .trash: .builtin(model.sidebarSelection)
        case .group(let id): .group(id)
        case .tag(let id): .tag(id)
        }
        guard let node = tree.node(for: kind) else { return }
        expandAncestors(of: node)
        let row = outline.row(forItem: node)
        guard row >= 0, outline.selectedRow != row else { return }
        isSyncingSelection = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        isSyncingSelection = false
    }

    /// Expands the node's parent. `NSOutlineView.parent(forItem:)` is nil for children of collapsed
    /// items (they are not loaded yet), so the parent comes from the snapshot instead.
    private func expandAncestors(of node: SidebarNode) {
        let parentKind: SidebarNode.Kind? = switch node.kind {
        case .group(let id): model?.snapshot.groupsById[id]?.parentId.map { .group($0) }
        case .tag: .tagsHeader
        default: nil
        }
        if let parentKind, let parent = tree.node(for: parentKind), !outline.isItemExpanded(parent) {
            outline.expandItem(parent)
        }
    }

    private func restoreExpansion() {
        let expanded = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
        for root in tree.roots {
            switch root.kind {
            case .group(let id) where expanded.contains(id) && !root.children.isEmpty:
                outline.expandItem(root)
            case .tagsHeader where !UserDefaults.standard.bool(forKey: Self.tagsCollapsedKey):
                outline.expandItem(root)
            default: break
            }
        }
    }

    private func persistExpansion() {
        let ids = tree.roots.filter { outline.isItemExpanded($0) }.compactMap(\.groupId)
        UserDefaults.standard.set(ids, forKey: Self.expandedKey)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? tree.roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? tree.roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .tagsHeader
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.canSelect ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? SidebarNode)?.kind {
        case .divider: 13
        case .tagsHeader: 26
        default: outlineView.rowHeight
        }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode, let model else { return nil }
        switch node.kind {
        case .divider:
            return outlineView.makeView(withIdentifier: SidebarDividerView.identifier, owner: nil) ?? SidebarDividerView()
        case .tagsHeader:
            return outlineView.makeView(withIdentifier: SidebarHeaderCell.identifier, owner: nil) ?? SidebarHeaderCell()
        case .builtin(let scope):
            let cell = makeCell()
            let symbol = switch scope {
            case .all: "books.vertical"
            case .unfiled: "tray"
            default: "trash"
            }
            cell.configure(symbol: symbol, tint: nil, title: model.title(for: scope), count: model.counts[scope],
                           expandable: false, isExpanded: false)
            cell.setAccessibilityIdentifier("sidebar.\(scope.key)")
            return cell
        case .group(let id):
            let cell = makeCell()
            let expandable = !node.children.isEmpty
            cell.configure(symbol: "folder", tint: nil, title: model.snapshot.groupsById[id]?.name ?? "",
                           count: model.counts[.group(id)], expandable: expandable,
                           isExpanded: outlineView.isItemExpanded(node))
            cell.onToggle = { [weak self, weak node] in
                guard let self, let node else { return }
                if self.outline.isItemExpanded(node) { self.outline.animator().collapseItem(node) }
                else { self.outline.animator().expandItem(node) }
            }
            cell.name.delegate = self
            cell.setAccessibilityIdentifier("sidebar.group.\(model.snapshot.groupsById[id]?.name ?? id)")
            return cell
        case .tag(let id):
            let cell = makeCell()
            let tag = model.snapshot.tagsById[id]
            cell.configure(symbol: "circle.fill", tint: NSColor(hex: tag?.colorHex ?? "#8E8E93"), title: tag?.name ?? "",
                           count: model.counts[.tag(id)], expandable: false, isExpanded: false)
            cell.setAccessibilityIdentifier("sidebar.tag.\(tag?.name ?? id)")
            return cell
        }
    }

    private func makeCell() -> SidebarCell {
        let cell = outline.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell ?? SidebarCell()
        cell.onToggle = nil
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode,
              let scope = node.scope else { return }
        model?.sidebarSelection = scope
    }

    func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, expanded: true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, expanded: false) }

    private func expansionChanged(_ notification: Notification, expanded: Bool) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        if node.kind == .tagsHeader {
            UserDefaults.standard.set(!expanded, forKey: Self.tagsCollapsedKey)
        } else {
            persistExpansion()
            let row = outline.row(forItem: node)
            (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell)?.setExpanded(expanded, animated: true)
        }
    }

    // MARK: Renaming (SIDE-06/08)

    func beginRenaming(row: Int) {
        guard let node = outline.item(atRow: row) as? SidebarNode, let groupId = node.groupId,
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell else { return }
        renamingGroupId = groupId
        cell.name.isEditable = true
        cell.name.delegate = self
        outline.window?.makeFirstResponder(cell.name)
        cell.name.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let groupId = renamingGroupId, let model else { return }
        renamingGroupId = nil
        field.isEditable = false
        let original = model.snapshot.groupsById[groupId]?.name ?? ""
        if field.stringValue != original && !model.renameGroup(groupId, to: field.stringValue) {
            field.stringValue = original
        }
        update()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), let groupId = renamingGroupId else { return false }
        (control as? NSTextField)?.stringValue = model?.snapshot.groupsById[groupId]?.name ?? ""
        outline.window?.makeFirstResponder(outline)
        return true
    }

    // MARK: Context menus (SIDE-06/07/14, TRASH-06)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        let node = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? SidebarNode : nil
        switch node?.kind {
        case .none, .divider:
            menu.addItem(item("创建分组", "folder.badge.plus") { model.createGroup() })
            menu.addItem(item("搜索文献", "magnifyingglass") { model.showSearch() })
        case .builtin(.trash):
            let empty = item("清空回收站", "trash.slash") { model.confirmEmptyTrash() }
            empty.isEnabled = (model.counts[.trash] ?? 0) > 0
            menu.addItem(empty)
        case .builtin:
            break
        case .group(let id):
            let row = outline.clickedRow
            if model.snapshot.groupsById[id]?.parentId == nil {
                menu.addItem(item("新建子分组", "folder.badge.plus") { model.createGroup(parentId: id) })
            }
            menu.addItem(item("重命名", "pencil") { [weak self] in self?.beginRenaming(row: row) })
            menu.addItem(.separator())
            menu.addItem(item("删除分组", "trash") { model.confirmDeleteGroup(id) })
        case .tagsHeader:
            menu.addItem(item("新建标签…", "tag") { model.activeSheet = .tagEditor(tagId: nil, applyTo: []) })
        case .tag(let id):
            menu.addItem(item("编辑标签…", "pencil") { model.activeSheet = .tagEditor(tagId: id, applyTo: []) })
            menu.addItem(item("删除标签", "trash") { model.confirmDeleteTag(id) })
        }
    }

    private func item(_ title: String, _ symbol: String, action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem.closure(title, action)
        menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return menuItem
    }

    // MARK: Drag source (groups)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let id = (item as? SidebarNode)?.groupId else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id, forType: .folioGroup)
        return pasteboardItem
    }

    // MARK: Drop target

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let source = dragSource(info) else { return [] }
        var target = dropTarget(item: item as? SidebarNode, childIndex: index)
        // Keep groups below the built-ins: clamp a drop above the divider to the first group slot.
        if case .group = source, item == nil, index >= 0, index < tree.firstGroupIndex {
            outlineView.setDropItem(nil, dropChildIndex: tree.firstGroupIndex)
            target = .topLevelGap(index: 0)
        }
        switch SidebarDragRules.decide(source, target) {
        case .reject: return []
        case .moveGroup, .nestGroup: return .move
        case .trashItems: return .delete
        case .importFiles: return .copy
        case .addItems, .tagItems: return .link
        }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let model, let source = dragSource(info) else { return false }
        switch SidebarDragRules.decide(source, dropTarget(item: item as? SidebarNode, childIndex: index)) {
        case .reject:
            return false
        case let .nestGroup(id, parentId):
            model.moveGroup(id, toParent: parentId, index: model.snapshot.childGroups[parentId]?.count ?? 0)
        case let .moveGroup(id, parentId, index):
            model.moveGroup(id, toParent: parentId, index: adjustedIndex(for: id, parentId: parentId, proposed: index))
        case let .addItems(ids, groupId):
            model.addItems(ids, toGroup: groupId)
        case let .trashItems(ids):
            model.trashItems(ids)
        case let .tagItems(ids, tagId):
            model.setTag(tagId, on: ids, enabled: true)
            model.toasts.show("已添加标签「\(model.snapshot.tagsById[tagId]?.name ?? "")」", systemImage: "tag")
        case let .importFiles(urls, groupId):
            model.importer.importFiles(urls, toGroup: groupId)
        }
        return true
    }

    /// Moving down within the same parent: the proposed index counts the dragged group itself.
    private func adjustedIndex(for id: String, parentId: String?, proposed: Int) -> Int {
        guard let model, model.snapshot.groupsById[id]?.parentId == parentId else { return proposed }
        let siblings = parentId.map { model.snapshot.childGroups[$0] ?? [] } ?? model.snapshot.topLevelGroups
        if let current = siblings.firstIndex(of: id), current < proposed { return proposed - 1 }
        return proposed
    }

    private func dragSource(_ info: any NSDraggingInfo) -> SidebarDragSource? {
        let pasteboard = info.draggingPasteboard
        if let id = pasteboard.pasteboardItems?.first?.string(forType: .folioGroup) {
            return .group(id: id, hasChildren: !(model?.snapshot.childGroups[id] ?? []).isEmpty)
        }
        let dragged = ItemPasteboard.draggedItems(pasteboard)
        if let first = dragged.first {
            return .items(ids: dragged.map(\.itemId), from: ViewScope(key: first.scopeKey) ?? .all)
        }
        let urls = ItemPasteboard.fileURLs(pasteboard)
        return urls.isEmpty ? nil : .files(urls)
    }

    private func dropTarget(item: SidebarNode?, childIndex index: Int) -> SidebarDropTarget {
        guard let item else {
            if index >= tree.firstGroupIndex && index <= tree.groupsEndIndex {
                return .topLevelGap(index: index - tree.firstGroupIndex)
            }
            return .elsewhere
        }
        switch item.kind {
        case .builtin(let scope):
            return index == NSOutlineViewDropOnItemIndex ? .builtin(scope) : .elsewhere
        case .group(let id):
            let isTopLevel = model?.snapshot.groupsById[id]?.parentId == nil
            if index == NSOutlineViewDropOnItemIndex { return .group(id: id, isTopLevel: isTopLevel) }
            return isTopLevel ? .childGap(parentId: id, index: index) : .elsewhere
        case .tag(let id):
            return index == NSOutlineViewDropOnItemIndex ? .tag(id) : .elsewhere
        case .divider, .tagsHeader:
            return .elsewhere
        }
    }
}

/// Target that runs a closure, retained by the menu item that uses it.
final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}

extension NSMenuItem {
    /// A menu item that runs `handler` — keeps menu construction declarative.
    static func closure(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#8E8E93" }
        return String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}
