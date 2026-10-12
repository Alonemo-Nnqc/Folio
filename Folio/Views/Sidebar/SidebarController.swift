import AppKit
import FolioCore

/// The sidebar source list (SIDE-*): sections 文献库 / 分组 / 标签 as collapsible group rows, user
/// groups with the system disclosure triangle, and every drag-and-drop rule.
///
/// Like Finder's sidebar it never takes keyboard focus, so the selection is the quiet, translucent
/// sidebar highlight rather than the accent-coloured one of a focused list; keyboard commands go to
/// the item list. Groups are renamed by double-clicking or from the context menu.
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let outline = NSOutlineView()
    private let tree = SidebarTree()
    private weak var model: AppModel?
    private var isSyncingSelection = false
    private var isRestoringExpansion = false
    private var renamingGroupId: String?
    private static let expandedKey = "sidebarExpandedGroups"
    private static let collapsedSectionsKey = "sidebarCollapsedSections"

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
        // Row height, font and icon size follow 系统设置 ▸ 外观 ▸ 边栏图标大小.
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.refusesFirstResponder = true
        outline.allowsEmptySelection = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.folioItem, .folioGroup, .fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList
        outline.setAccessibilityIdentifier("sidebar")
        outline.setAccessibilityLabel("边栏")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
    }

    // MARK: Updates from the model

    func update() {
        // Reloading rows would reconfigure the cell being edited and end the rename.
        guard let model, renamingGroupId == nil else { return }
        if tree.rebuild(from: model.snapshot) {
            // Reloading drops the selection and AppKit selects the first row on its own; that must not
            // reach the model, or the view would jump to 所有文献. syncSelection() restores it below.
            isSyncingSelection = true
            outline.reloadData()
            restoreExpansion()
            isSyncingSelection = false
        } else {
            let visible = outline.rows(in: outline.visibleRect)
            outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
                               columnIndexes: [0])
        }
        if model.previewExpandAllGroups {
            model.previewExpandAllGroups = false
            isSyncingSelection = true
            outline.expandItem(nil, expandChildren: true)
            isSyncingSelection = false
        }
        syncSelection()
        if let pending = model.groupPendingRename, let node = tree.node(for: .group(pending)) {
            model.groupPendingRename = nil
            expandAncestors(of: node)
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.scrollRowToVisible(row)
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

    /// Expands the section and parent group of a node. `NSOutlineView.parent(forItem:)` is nil for
    /// children of collapsed items (they are not loaded yet), so parents come from the snapshot.
    private func expandAncestors(of node: SidebarNode) {
        var chain: [SidebarNode.Kind] = []
        switch node.kind {
        case .builtin: chain = [.libraryHeader]
        case .tag: chain = [.tagsHeader]
        case .group(let id):
            chain = [.groupsHeader]
            if let parent = model?.snapshot.groupsById[id]?.parentId { chain.append(.group(parent)) }
        default: break
        }
        let wasSyncing = isSyncingSelection
        isSyncingSelection = true
        for kind in chain {
            if let parent = tree.node(for: kind), !outline.isItemExpanded(parent) { outline.expandItem(parent) }
        }
        isSyncingSelection = wasSyncing
    }

    private func restoreExpansion() {
        isRestoringExpansion = true
        defer { isRestoringExpansion = false }
        let collapsedSections = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedSectionsKey) ?? [])
        let expandedGroups = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
        for section in tree.roots where !collapsedSections.contains(Self.key(section.kind)) {
            outline.expandItem(section)
        }
        if let groups = tree.node(for: .groupsHeader) {
            for group in groups.children where expandedGroups.contains(group.groupId ?? "") && !group.children.isEmpty {
                outline.expandItem(group)
            }
        }
    }

    private func persistExpansion() {
        guard !isRestoringExpansion, !UserDefaults.standard.bool(forKey: "FolioUITesting") else { return }
        let collapsed = tree.roots.filter { !outline.isItemExpanded($0) }.map { Self.key($0.kind) }
        UserDefaults.standard.set(collapsed, forKey: Self.collapsedSectionsKey)
        let expanded = (tree.node(for: .groupsHeader)?.children ?? []).filter { outline.isItemExpanded($0) }.compactMap(\.groupId)
        UserDefaults.standard.set(expanded, forKey: Self.expandedKey)
    }

    private static func key(_ kind: SidebarNode.Kind) -> String {
        switch kind {
        case .libraryHeader: "library"
        case .groupsHeader: "groups"
        case .tagsHeader: "tags"
        default: ""
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? tree.roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? tree.roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        // Sections stay collapsible even when empty, so their + is always there.
        return node.isHeader || !node.children.isEmpty
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isHeader ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.canSelect ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode, let model else { return nil }
        switch node.kind {
        case .libraryHeader:
            return header(title: "文献库", addTitle: nil, action: nil, identifier: nil)
        case .groupsHeader:
            return header(title: "分组", addTitle: "新建分组", action: #selector(LibraryWindowController.newGroup(_:)),
                          identifier: "sidebar.addGroup")
        case .tagsHeader:
            return header(title: "标签", addTitle: "新建标签", action: #selector(LibraryWindowController.newTag(_:)),
                          identifier: "sidebar.addTag")
        case .builtin(let scope):
            let cell = makeCell()
            let symbol = switch scope {
            case .all: "books.vertical"
            case .unfiled: "tray"
            default: "trash"
            }
            cell.configure(symbol: symbol, tint: nil, title: model.title(for: scope), count: model.counts[scope])
            cell.setAccessibilityIdentifier("sidebar.\(scope.key)")
            return cell
        case .group(let id):
            let cell = makeCell()
            let name = model.snapshot.groupsById[id]?.name ?? ""
            cell.configure(symbol: "folder", tint: nil, title: name, count: model.counts[.group(id)])
            cell.name.delegate = self
            cell.setAccessibilityIdentifier("sidebar.group.\(name)")
            return cell
        case .tag(let id):
            let cell = makeCell()
            let tag = model.snapshot.tagsById[id]
            cell.configure(symbol: "circle.fill", tint: NSColor(hex: tag?.colorHex ?? "#8E8E93"), title: tag?.name ?? "",
                           count: model.counts[.tag(id)])
            cell.setAccessibilityIdentifier("sidebar.tag.\(tag?.name ?? id)")
            return cell
        }
    }

    private func header(title: String, addTitle: String?, action: Selector?, identifier: String?) -> NSView {
        let cell = outline.makeView(withIdentifier: SidebarHeaderCell.identifier, owner: nil) as? SidebarHeaderCell
            ?? SidebarHeaderCell()
        cell.configure(title: title, addTitle: addTitle, action: action, identifier: identifier)
        return cell
    }

    private func makeCell() -> SidebarCell {
        outline.makeView(withIdentifier: SidebarCell.identifier, owner: nil) as? SidebarCell ?? SidebarCell()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection, let node = outline.item(atRow: outline.selectedRow) as? SidebarNode,
              let scope = node.scope else { return }
        model?.sidebarSelection = scope
    }

    func outlineViewItemDidExpand(_ notification: Notification) { persistExpansion() }
    func outlineViewItemDidCollapse(_ notification: Notification) { persistExpansion() }

    // MARK: Renaming (SIDE-06/08)

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return }
        if node.groupId != nil {
            beginRenaming(row: row)
        } else if node.isHeader {
            outline.isItemExpanded(node) ? outline.animator().collapseItem(node) : outline.animator().expandItem(node)
        }
    }

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
        control.window?.makeFirstResponder(nil)
        return true
    }

    // MARK: Context menus (SIDE-06/07/14, TRASH-06)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        let node = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? SidebarNode : nil
        switch node?.kind {
        case .none, .libraryHeader, .groupsHeader:
            menu.addItem(item("创建分组", "folder.badge.plus") { model.createGroup() })
            menu.addItem(item("搜索文献", "magnifyingglass") { model.showSearch() })
        case .builtin(.trash):
            let empty = item("清空回收站…", "trash.slash") { model.confirmEmptyTrash() }
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
            menu.addItem(item("删除分组…", "trash") { model.confirmDeleteGroup(id) })
        case .tagsHeader:
            menu.addItem(item("新建标签…", "tag") { model.activeSheet = .tagEditor(tagId: nil, applyTo: []) })
        case .tag(let id):
            menu.addItem(item("编辑标签…", "pencil") { model.activeSheet = .tagEditor(tagId: id, applyTo: []) })
            menu.addItem(item("删除标签…", "trash") { model.confirmDeleteTag(id) })
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

    /// Sidebar node for a group name (simulated-drop checks).
    func node(forGroupNamed name: String) -> SidebarNode? {
        guard let id = model?.snapshot.groupsById.values.first(where: { $0.name == name })?.id else { return nil }
        return tree.node(for: .group(id))
    }

    // MARK: Drop target

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let source = dragSource(info) else { return [] }
        switch SidebarDragRules.decide(source, dropTarget(item: item as? SidebarNode, childIndex: index)) {
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

    /// Maps the outline's proposal onto the sidebar's drop vocabulary. Top-level groups are the
    /// children of the 分组 section, so their gaps are child indexes of that header.
    private func dropTarget(item: SidebarNode?, childIndex index: Int) -> SidebarDropTarget {
        guard let item else { return .elsewhere }
        let onItem = index == NSOutlineViewDropOnItemIndex
        switch item.kind {
        case .groupsHeader:
            return .topLevelGap(index: onItem ? item.children.count : index)
        case .builtin(let scope):
            return onItem ? .builtin(scope) : .elsewhere
        case .group(let id):
            let isTopLevel = model?.snapshot.groupsById[id]?.parentId == nil
            if onItem { return .group(id: id, isTopLevel: isTopLevel) }
            return isTopLevel ? .childGap(parentId: id, index: index) : .elsewhere
        case .tag(let id):
            return onItem ? .tag(id) : .elsewhere
        case .libraryHeader, .tagsHeader:
            return .elsewhere
        }
    }
}
