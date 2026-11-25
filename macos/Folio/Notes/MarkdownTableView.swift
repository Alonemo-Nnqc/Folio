import AppKit

/// A table of a document, written in where it stands: every cell is a small editor (Tab and Return go on to the next
/// cell, a new row after the last), columns and rows are added, moved and removed with the handles at its edges.
final class MarkdownTableView: NSView {
    /// What the view has around the table for its handles.
    static let overhang: CGFloat = 9
    private static let trailing: CGFloat = 20
    private static let bottom: CGFloat = 18
    private static let minColumn: CGFloat = 64
    private static let maxColumn: CGFloat = 340

    private(set) var table = MarkdownTable(rows: [], alignments: [])
    private let styler: MarkdownStyler
    private weak var owner: MarkdownTextView?
    private var cells: [[MarkdownCellView]] = []
    private var widths: [CGFloat] = []
    private var heights: [CGFloat] = []
    /// A table wider than the text scrolls sideways.
    private var offset: CGFloat = 0
    private var laidOutWidth: CGFloat = 0
    private var isDirty = true
    private let clip = FlippedClip()
    private let addColumn = MarkdownTableHandle(.addColumn), addRow = MarkdownTableHandle(.addRow)
    private let columnHandle = MarkdownTableHandle(.column), rowHandle = MarkdownTableHandle(.row)
    private var hovered: (row: Int, column: Int)?
    /// The whole table is selected (with the text around it, or alone).
    var isSelected = false { didSet { if isSelected != oldValue { clip.needsDisplay = true } } }
    /// The cells selected together (dragged over).
    private(set) var selected: (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? { didSet { clip.needsDisplay = true } }

    init(styler: MarkdownStyler, owner: MarkdownTextView) {
        self.styler = styler
        self.owner = owner
        super.init(frame: .zero)
        clip.clipsToBounds = true
        addSubview(clip)
        for handle in [addColumn, addRow, columnHandle, rowHandle] {
            handle.isHidden = true
            addSubview(handle)
        }
        addColumn.toolTip = String(localized: "添加一列")
        addRow.toolTip = String(localized: "添加一行")
        columnHandle.toolTip = String(localized: "这一列")
        rowHandle.toolTip = String(localized: "这一行")
        addColumn.onClick = { [weak self] in self.map { $0.insertColumn(at: $0.table.columns) } }
        addRow.onClick = { [weak self] in self.map { $0.insertRow(at: $0.table.rows.count) } }
        columnHandle.onClick = { [weak self] in
            guard let self, let column = self.hovered?.column else { return }
            self.columnMenu(column).popUp(positioning: nil, at: NSPoint(x: self.columnHandle.frame.minX, y: self.columnHandle.frame.maxY + 4), in: self)
        }
        rowHandle.onClick = { [weak self] in
            guard let self, let row = self.hovered?.row else { return }
            self.rowMenu(row).popUp(positioning: nil, at: NSPoint(x: self.rowHandle.frame.maxX + 2, y: self.rowHandle.frame.minY), in: self)
        }
        clip.onDraw = { [weak self] in self?.drawGrid() }
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
        setAccessibilityLabel(String(localized: "表格"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }

    // MARK: Showing

    func show(_ new: MarkdownTable) {
        let shapeChanged = new.rows.count != cells.count || new.columns != (cells.first?.count ?? 0)
        guard shapeChanged || new != table else { return }
        // The keyboard goes back to the text before its cell goes.
        if let cell = focusedCell, cell.row >= new.rows.count || cell.column >= new.columns, let owner { window?.makeFirstResponder(owner) }
        table = new
        isDirty = true
        while cells.count > new.rows.count { cells.removeLast().forEach { $0.removeFromSuperview() } }
        while cells.count < new.rows.count { cells.append([]) }
        for row in cells.indices {
            while cells[row].count > new.columns { cells[row].removeLast().removeFromSuperview() }
            while cells[row].count < new.columns {
                let cell = MarkdownCellView(styler: styler, table: self)
                cells[row].append(cell)
                clip.addSubview(cell)
            }
            for column in cells[row].indices {
                let cell = cells[row][column]
                cell.row = row
                cell.column = column
                cell.show(new.rows[row][column], alignment: new.alignments[column], isHeader: row == 0)
            }
        }
    }

    /// Out of the text for good.
    func remove() {
        if focusedCell != nil, let owner { window?.makeFirstResponder(owner) }
        removeFromSuperview()
    }

    private var focusedCell: MarkdownCellView? { (window?.firstResponder as? MarkdownCellView).flatMap { $0.table === self ? $0 : nil } }

    /// Lays the cells out in `width`; what the view then takes.
    func layout(width: CGFloat) -> CGFloat {
        guard isDirty || abs(width - laidOutWidth) > 0.5 else { return frame.height }
        isDirty = false
        laidOutWidth = width
        let room = max(width - Self.trailing, 40)
        let natural = (0..<table.columns).map { column in
            min(max(cells.map { $0[column].naturalWidth }.max() ?? 0, Self.minColumn), Self.maxColumn)
        }
        widths = natural
        var total = natural.reduce(0, +)
        if total > room, table.columns > 0 {
            // Wide columns give way first: each gets its fair share of what the narrow ones leave.
            var open = Set(natural.indices), left = room
            while true {
                let share = left / CGFloat(max(open.count, 1))
                let fitting = open.filter { natural[$0] <= share }
                if fitting.isEmpty || open.isEmpty { open.forEach { widths[$0] = max(floor(share), min(Self.minColumn, natural[$0])) }; break }
                fitting.forEach { left -= natural[$0]; open.remove($0) }
                if open.isEmpty { break }
            }
            total = widths.reduce(0, +)
        }
        heights = cells.map { row in
            ceil(row.enumerated().map { column, cell in cell.height(width: widths[column]) }.max() ?? 30)
        }
        let height = heights.reduce(0, +)
        let shown = min(total, room)
        offset = min(max(offset, 0), max(total - shown, 0))
        clip.frame = NSRect(x: Self.overhang, y: Self.overhang, width: shown, height: height)
        setFrameSize(NSSize(width: Self.overhang + width + 2, height: Self.overhang + height + Self.bottom))
        placeCells()
        return frame.height
    }

    private func placeCells() {
        var y: CGFloat = 0
        for (row, line) in cells.enumerated() {
            var x = -offset
            for (column, cell) in line.enumerated() {
                cell.frame = NSRect(x: x, y: y, width: widths[column], height: heights[row])
                x += widths[column]
            }
            y += heights[row]
        }
        clip.needsDisplay = true
        placeHandles()
    }

    private func drawGrid() {
        let bounds = clip.bounds
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let first = heights.first {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: first).fill()
        }
        NSColor.separatorColor.setFill()
        var y: CGFloat = 0
        for height in heights.dropLast() { y += height; NSRect(x: 0, y: y - 0.5, width: bounds.width, height: 1).fill() }
        var x = -offset
        for width in widths.dropLast() { x += width; NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill() }
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            bounds.fill()
        }
        if let selected, cells.indices.contains(selected.rows.upperBound), cells[0].indices.contains(selected.columns.upperBound) {
            let area = cells[selected.rows.lowerBound][selected.columns.lowerBound].frame.union(cells[selected.rows.upperBound][selected.columns.upperBound].frame)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            area.fill()
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: area.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            ring.lineWidth = 1.5
            ring.stroke()
        } else if let cell = focusedCell {
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(roundedRect: cell.frame.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            ring.lineWidth = 1.5
            ring.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        let overflow = widths.reduce(0, +) - clip.bounds.width
        guard overflow > 0.5, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return super.scrollWheel(with: event) }
        offset = min(max(offset - event.scrollingDeltaX, 0), overflow)
        placeCells()
    }

    func cellFocusChanged(_ cell: MarkdownCellView, focused: Bool) {
        selected = nil
        clip.needsDisplay = true
        guard focused, cell.frame.minX < 0 || cell.frame.maxX > clip.bounds.width else { return }
        offset += cell.frame.minX < 0 ? cell.frame.minX : cell.frame.maxX - clip.bounds.width
        offset = max(offset, 0)
        placeCells()
    }

    // MARK: Handles

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        placeHandles()
    }

    func hover(at point: NSPoint) {
        var row = 0, column = 0, y = Self.overhang, x = Self.overhang - offset
        for (index, height) in heights.enumerated() { row = index; y += height; if point.y < y { break } }
        for (index, width) in widths.enumerated() { column = index; x += width; if point.x < x { break } }
        hovered = (row, column)
        placeHandles()
    }

    private func placeHandles() {
        let shows = hovered != nil && owner?.isEditable != false && !widths.isEmpty && !heights.isEmpty
        for handle in [addColumn, addRow, columnHandle, rowHandle] { handle.isHidden = !shows }
        guard shows, let hovered, widths.indices.contains(hovered.column), heights.indices.contains(hovered.row) else { return }
        let box = clip.frame
        addColumn.frame = NSRect(x: box.maxX + 3, y: box.minY, width: 14, height: box.height)
        addRow.frame = NSRect(x: box.minX, y: box.maxY + 3, width: box.width, height: 13)
        let x = box.minX - offset + widths[..<hovered.column].reduce(0, +) + widths[hovered.column] / 2
        let y = box.minY + heights[..<hovered.row].reduce(0, +) + heights[hovered.row] / 2
        columnHandle.frame = NSRect(x: min(max(x - 14, box.minX), box.maxX - 28), y: box.minY - 6, width: 28, height: 12)
        rowHandle.frame = NSRect(x: box.minX - 6, y: y - 11, width: 12, height: 22)
    }

    // MARK: The keyboard

    func focus(_ place: MarkdownBlockViews.Place, selecting: Bool = false) {
        guard let line = place == .start ? cells.first : cells.last, let cell = place == .start ? line.first : line.last else { return }
        focus(cell, selecting: selecting)
    }

    private func focus(_ cell: MarkdownCellView, selecting: Bool = false, atEnd: Bool = true) {
        window?.makeFirstResponder(cell)
        let length = (cell.string as NSString).length
        cell.setSelectedRange(selecting ? NSRange(location: 0, length: length) : NSRange(location: atEnd ? length : 0, length: 0))
        owner?.scrollToVisible(convert(cell.frame, from: clip).insetBy(dx: 0, dy: -12).offsetBy(dx: frame.minX, dy: frame.minY))
    }

    /// Tab and Shift-Tab: cell by cell, a new row after the last.
    func step(from cell: MarkdownCellView, by step: Int) {
        let index = cell.row * table.columns + cell.column + step
        if index < 0 { return leave(.start) }
        if index >= table.rows.count * table.columns { insertRow(at: table.rows.count, column: 0); return }
        focus(cells[index / table.columns][index % table.columns], selecting: true)
    }

    /// Up, down and Return: the cell above or below, then out of the table (Return: a new row).
    func stepRow(from cell: MarkdownCellView, by step: Int, adding: Bool = false) {
        let row = cell.row + step
        if row < 0 { return leave(.start) }
        if row >= cells.count {
            if adding { insertRow(at: table.rows.count, column: cell.column) } else { leave(.end) }
            return
        }
        focus(cells[row][cell.column])
    }

    func stepColumn(from cell: MarkdownCellView, by step: Int) {
        let index = cell.row * table.columns + cell.column + step
        if index < 0 { return leave(.start) }
        if index >= table.rows.count * table.columns { return leave(.end) }
        focus(cells[index / table.columns][index % table.columns], atEnd: step < 0)
    }

    func leave(_ place: MarkdownBlockViews.Place) { owner?.blockViews.leave(self, place) }

    /// For tests.
    func cell(_ row: Int, _ column: Int) -> MarkdownCellView { cells[row][column] }
    func cellCenter(_ row: Int, _ column: Int) -> NSPoint { clip.convert(NSPoint(x: cells[row][column].frame.midX, y: cells[row][column].frame.midY), to: nil) }

    // MARK: Cells selected together

    /// Dragged from a cell to a point of this view: the cells between (outside the table: the table).
    func select(from cell: MarkdownCellView, to point: NSPoint) {
        guard !heights.isEmpty else { return }
        var row = heights.count - 1, column = widths.count - 1, y = Self.overhang, x = Self.overhang - offset
        for (index, height) in heights.enumerated() { y += height; if point.y < y { row = index; break } }
        for (index, width) in widths.enumerated() { x += width; if point.x < x { column = index; break } }
        let rows = min(row, cell.row)...max(row, cell.row), columns = min(column, cell.column)...max(column, cell.column)
        selected = rows.count == 1 && columns.count == 1 ? nil : (rows, columns)
    }

    func clearSelected() { selected = nil }

    /// Delete on cells selected together: all of them, the table goes; whole rows or columns go; others are emptied.
    func deleteSelected() -> Bool {
        guard let selected else { return false }
        self.selected = nil
        let allRows = selected.rows.count == table.rows.count, allColumns = selected.columns.count == table.columns
        if allRows, allColumns { removeTable(); return true }
        var new = table
        if allColumns, selected.rows.lowerBound > 0 {
            new.rows.removeSubrange(selected.rows)
            restructure(new, focus: (min(selected.rows.lowerBound, new.rows.count - 1), 0))
        } else if allRows {
            for row in new.rows.indices { new.rows[row].removeSubrange(selected.columns) }
            new.alignments.removeSubrange(selected.columns)
            restructure(new, focus: (0, min(selected.columns.lowerBound, new.columns - 1)))
        } else {
            for row in selected.rows { for column in selected.columns { new.rows[row][column] = "" } }
            restructure(new, focus: (selected.rows.lowerBound, selected.columns.lowerBound))
        }
        return true
    }

    /// The cells selected together, for other apps' tables too.
    var selectedText: String? {
        selected.map { selected in table.rows[selected.rows].map { $0[selected.columns].joined(separator: "\t") }.joined(separator: "\n") }
    }

    var isBlank: Bool { table.rows.allSatisfy { $0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } } }

    func selectAll() { owner?.blockViews.selectTable(self) }

    // MARK: Editing

    /// What was typed in a cell goes into the document's text.
    func cellChanged(_ cell: MarkdownCellView) {
        guard table.rows.indices.contains(cell.row), table.rows[cell.row].indices.contains(cell.column) else { return }
        var new = table
        new.rows[cell.row][cell.column] = cell.string
        guard new != table else { return }
        table = new
        isDirty = true
        owner?.blockViews.write(self, new, typing: true)
    }

    /// A row or column added, moved or removed; the caret in the cell told.
    private func restructure(_ new: MarkdownTable, focus target: (row: Int, column: Int)?) {
        show(new)
        owner?.blockViews.write(self, new)
        guard let target, cells.indices.contains(target.row), cells[target.row].indices.contains(target.column) else { return }
        focus(cells[target.row][target.column])
    }

    func insertRow(at row: Int, column: Int = 0) {
        var new = table
        let row = min(max(row, 1), new.rows.count)
        new.rows.insert(Array(repeating: "", count: new.columns), at: row)
        restructure(new, focus: (row, column))
    }

    func insertColumn(at column: Int, row: Int = 0) {
        var new = table
        for index in new.rows.indices { new.rows[index].insert("", at: column) }
        new.alignments.insert(.none, at: column)
        restructure(new, focus: (row, column))
    }

    private func moveRow(_ row: Int, by step: Int) {
        var new = table
        new.rows.swapAt(row, row + step)
        restructure(new, focus: (row + step, 0))
    }

    private func moveColumn(_ column: Int, by step: Int) {
        var new = table
        for index in new.rows.indices { new.rows[index].swapAt(column, column + step) }
        new.alignments.swapAt(column, column + step)
        restructure(new, focus: (0, column + step))
    }

    private func removeRow(_ row: Int) {
        guard table.rows.count > 1 else { return removeTable() }
        var new = table
        new.rows.remove(at: row)
        restructure(new, focus: (min(row, new.rows.count - 1), 0))
    }

    private func removeColumn(_ column: Int) {
        guard table.columns > 1 else { return removeTable() }
        var new = table
        for index in new.rows.indices { new.rows[index].remove(at: column) }
        new.alignments.remove(at: column)
        restructure(new, focus: (0, min(column, new.columns - 1)))
    }

    private func align(_ column: Int, _ alignment: MarkdownTable.Alignment) {
        var new = table
        new.alignments[column] = alignment
        restructure(new, focus: nil)
    }

    func removeTable() { owner?.blockViews.write(self, nil) }

    /// Rows and columns from another app (or another table), from a cell on; the table grows for them.
    func paste(_ grid: [[String]], at cell: MarkdownCellView) {
        var new = table
        let columns = cell.column + (grid.map(\.count).max() ?? 0)
        while new.columns < columns {
            for index in new.rows.indices { new.rows[index].append("") }
            new.alignments.append(.none)
        }
        for (r, values) in grid.enumerated() {
            if cell.row + r >= new.rows.count { new.rows.append(Array(repeating: "", count: new.columns)) }
            for (c, value) in values.enumerated() { new.rows[cell.row + r][cell.column + c] = value }
        }
        restructure(new, focus: (cell.row, cell.column))
    }

    // MARK: Menus

    private func item(_ title: String, _ symbol: String, enabled: Bool = true, on: Bool = false, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = BlockAction(action)
        let item = NSMenuItem(title: title, action: #selector(BlockAction.perform(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = enabled
        item.state = on ? .on : .off
        return item
    }

    private func menu(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    private func columnItems(_ column: Int) -> [NSMenuItem] {
        [
            item(String(localized: "左对齐"), "text.alignleft", on: [.left, .none].contains(table.alignments[column])) { [weak self] in self?.align(column, .left) },
            item(String(localized: "居中"), "text.aligncenter", on: table.alignments[column] == .center) { [weak self] in self?.align(column, .center) },
            item(String(localized: "右对齐"), "text.alignright", on: table.alignments[column] == .right) { [weak self] in self?.align(column, .right) },
            .separator(),
            item(String(localized: "在左侧插入列"), "arrow.left.to.line") { [weak self] in self?.insertColumn(at: column) },
            item(String(localized: "在右侧插入列"), "arrow.right.to.line") { [weak self] in self?.insertColumn(at: column + 1) },
            item(String(localized: "左移"), "arrow.left", enabled: column > 0) { [weak self] in self?.moveColumn(column, by: -1) },
            item(String(localized: "右移"), "arrow.right", enabled: column < table.columns - 1) { [weak self] in self?.moveColumn(column, by: 1) },
            .separator(),
            item(String(localized: "删除列"), "trash") { [weak self] in self?.removeColumn(column) },
        ]
    }

    private func rowItems(_ row: Int) -> [NSMenuItem] {
        [
            item(String(localized: "在上方插入行"), "arrow.up.to.line", enabled: row > 0) { [weak self] in self?.insertRow(at: row) },
            item(String(localized: "在下方插入行"), "arrow.down.to.line") { [weak self] in self?.insertRow(at: row + 1) },
            item(String(localized: "上移"), "arrow.up", enabled: row > 1) { [weak self] in self?.moveRow(row, by: -1) },
            item(String(localized: "下移"), "arrow.down", enabled: row > 0 && row < table.rows.count - 1) { [weak self] in self?.moveRow(row, by: 1) },
            .separator(),
            item(String(localized: "删除行"), "trash", enabled: row > 0 || table.rows.count == 1) { [weak self] in self?.removeRow(row) },
        ]
    }

    private func columnMenu(_ column: Int) -> NSMenu { menu(columnItems(column)) }

    private func rowMenu(_ row: Int) -> NSMenu {
        menu(rowItems(row) + [item(String(localized: "删除表格"), "xmark.bin") { [weak self] in self?.removeTable() }])
    }

    /// What a cell's own menu has before the text's commands.
    func addItems(to menu: NSMenu, for cell: MarkdownCellView) {
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = self.menu(items)
            return item
        }
        let items = [sub(String(localized: "行"), rowItems(cell.row)), sub(String(localized: "列"), columnItems(cell.column)),
                     item(String(localized: "删除表格"), "xmark.bin") { [weak self] in self?.removeTable() }, .separator()]
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
    }
}

private final class FlippedClip: NSView {
    var onDraw: () -> Void = {}
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { onDraw() }
}

/// A handle at a table's edge.
private final class MarkdownTableHandle: NSView {
    enum Kind { case addColumn, addRow, column, row }
    let kind: Kind
    var onClick: () -> Void = {}
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        switch kind {
        case .addColumn, .addRow:
            NSColor.labelColor.withAlphaComponent(hovering ? 0.1 : 0.04).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            (hovering ? NSColor.secondaryLabelColor : .tertiaryLabelColor).setStroke()
            let plus = NSBezierPath()
            plus.move(to: NSPoint(x: bounds.midX - 3.5, y: bounds.midY)); plus.line(to: NSPoint(x: bounds.midX + 3.5, y: bounds.midY))
            plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 3.5)); plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 3.5))
            plus.lineWidth = 1.2
            plus.stroke()
        case .column, .row:
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            (hovering ? NSColor.controlAccentColor : NSColor.textBackgroundColor).setFill()
            path.fill()
            (hovering ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = 1
            path.stroke()
            (hovering ? NSColor.white : NSColor.tertiaryLabelColor).setFill()
            for index in -1...1 {
                let center = kind == .column ? NSPoint(x: bounds.midX + CGFloat(index) * 5, y: bounds.midY) : NSPoint(x: bounds.midX, y: bounds.midY + CGFloat(index) * 5)
                NSBezierPath(ovalIn: NSRect(x: center.x - 1.1, y: center.y - 1.1, width: 2.2, height: 2.2)).fill()
            }
        }
    }
}

// MARK: - Cells

/// One cell: a small text editor with the look of the text around it.
final class MarkdownCellView: NSTextView, NSTextViewDelegate {
    private static let inset = NSSize(width: 9, height: 7)
    private(set) weak var table: MarkdownTableView?
    private let styler: MarkdownStyler
    var row = 0, column = 0
    private var columnAlignment = MarkdownTable.Alignment.none
    private var isHeader = false
    private var isShowing = false

    init(styler: MarkdownStyler, table: MarkdownTableView) {
        self.styler = styler
        self.table = table
        let storage = NSTextStorage()
        let layout = MarkdownLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        textContainerInset = Self.inset
        isRichText = false
        drawsBackground = false
        // Undone with the document (`MarkdownTableView.registerUndo`).
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        delegate = self
        setAccessibilityIdentifier("tableCell")
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        styler = MarkdownStyler()
        super.init(frame: frame, textContainer: textContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    func show(_ text: String, alignment: MarkdownTable.Alignment, isHeader: Bool) {
        let restyle = self.columnAlignment != alignment || self.isHeader != isHeader
        self.columnAlignment = alignment
        self.isHeader = isHeader
        if string != text, string.trimmingCharacters(in: .whitespacesAndNewlines) != text || window?.firstResponder !== self {
            isShowing = true
            let caret = selectedRange().location
            string = text
            isShowing = false
            setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
            style()
        } else if restyle { style() }
    }

    private func style(focused: Bool? = nil) {
        guard let storage = textStorage, !hasMarkedText() else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(round(styler.fontSize * min(styler.preferences.lineHeight, 1.8) - MarkdownStyler.lineHeight(styler.bodyFont)) / 2, 1)
        paragraph.alignment = switch columnAlignment {
        case .none, .left: .left
        case .center: .center
        case .right: .right
        }
        let font = isHeader ? styler.font(styler.fontSize, .semibold) : styler.bodyFont
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        for key in MarkdownStyler.ownedKeys { storage.removeAttribute(key, range: whole) }
        storage.addAttributes(base, range: whole)
        let caret = focused ?? (window?.firstResponder === self) ? selectedRange() : nil
        styler.styleInline(storage, range: whole, caret: caret)
        storage.fixAttributes(in: whole)
        storage.endEditing()
        typingAttributes = base
        defaultParagraphStyle = paragraph
    }

    var naturalWidth: CGFloat {
        guard let storage = textStorage else { return 0 }
        let size = storage.boundingRect(with: NSSize(width: 2000, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(size.width) + Self.inset.width * 2 + 4
    }

    func height(width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 30 }
        if abs(textContainer.size.width - (width - Self.inset.width * 2)) > 0.1 {
            textContainer.size = NSSize(width: max(width - Self.inset.width * 2, 10), height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)
        let line = MarkdownStyler.lineHeight(styler.bodyFont)
        return max(layoutManager.usedRect(for: textContainer).height, line) + Self.inset.height * 2
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { style(focused: true); table?.cellFocusChanged(self, focused: true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            style(focused: false)
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            table?.cellFocusChanged(self, focused: false)
        }
        return accepted
    }

    func textDidChange(_ notification: Notification) {
        guard !isShowing, !hasMarkedText() else { return }
        style()
        table?.cellChanged(self)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isShowing, window?.firstResponder === self, string.rangeOfCharacter(from: CharacterSet(charactersIn: "*_~=`[<")) != nil else { return }
        style()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        if url.scheme == "folio" { AppDelegate.shared.open(folioLink: url.absoluteString) } else { NSWorkspace.shared.open(url) }
        return true
    }

    private func isOnLine(_ edge: NSRectEdge) -> Bool {
        guard let layoutManager, selectedRange().length == 0 else { return false }
        let count = layoutManager.numberOfGlyphs
        guard count > 0 else { return true }
        let caret = selectedRange().location
        if edge == .maxY {
            if !layoutManager.extraLineFragmentRect.isEmpty { return caret == (string as NSString).length }
            let last = layoutManager.lineFragmentRect(forGlyphAt: count - 1, effectiveRange: nil)
            return layoutManager.lineFragmentRect(forGlyphAt: min(layoutManager.glyphIndexForCharacter(at: min(caret, (string as NSString).length - 1)), count - 1), effectiveRange: nil).minY >= last.minY - 0.5
        }
        if !layoutManager.extraLineFragmentRect.isEmpty, caret == (string as NSString).length { return false }
        return layoutManager.lineFragmentRect(forGlyphAt: min(layoutManager.glyphIndexForCharacter(at: min(caret, (string as NSString).length - 1)), count - 1), effectiveRange: nil).minY < 0.5
    }

    override func doCommand(by selector: Selector) {
        guard let table, !hasMarkedText() else { return super.doCommand(by: selector) }
        let caret = selectedRange()
        switch selector {
        case #selector(insertTab(_:)): table.step(from: self, by: 1)
        case #selector(insertBacktab(_:)): table.step(from: self, by: -1)
        case #selector(insertNewline(_:)): table.stepRow(from: self, by: 1, adding: true)
        case #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)): insertText("\n", replacementRange: caret)
        case #selector(moveUp(_:)) where isOnLine(.minY): table.stepRow(from: self, by: -1)
        case #selector(moveDown(_:)) where isOnLine(.maxY): table.stepRow(from: self, by: 1)
        case #selector(moveLeft(_:)) where caret.length == 0 && caret.location == 0: table.stepColumn(from: self, by: -1)
        case #selector(moveRight(_:)) where caret.length == 0 && caret.location == (string as NSString).length: table.stepColumn(from: self, by: 1)
        case #selector(cancelOperation(_:)):
            if table.selected != nil { table.clearSelected() } else { table.selectAll() }
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
            if table.deleteSelected() { return }
            // Nothing left in it: the table is selected, and goes with the next one.
            if string.isEmpty, table.isBlank { return table.selectAll() }
            super.doCommand(by: selector)
        default: super.doCommand(by: selector)
        }
    }

    override func paste(_ sender: Any?) {
        guard let table, let text = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        if text.contains("\t") { return table.paste(lines.map { $0.components(separatedBy: "\t") }, at: self) }
        insertText(lines.joined(separator: "\n"), replacementRange: selectedRange())
    }

    override func copy(_ sender: Any?) {
        guard let text = table?.selectedText else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard table?.selected != nil else { return super.cut(sender) }
        copy(sender)
        _ = table?.deleteSelected()
    }

    /// ⌘A: the cell's text, then the whole table.
    override func selectAll(_ sender: Any?) {
        let length = (string as NSString).length
        if length == 0 || selectedRange().length == length { table?.selectAll() } else { super.selectAll(sender) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if table?.selected != nil { table?.clearSelected() }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// Dragged out of the cell: the cells between are selected together.
    override func mouseDown(with event: NSEvent) {
        guard let table, let window, event.clickCount == 1, !event.modifierFlags.contains(.shift), !hasMarkedText() else { return super.mouseDown(with: event) }
        let start = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        table.clearSelected()
        window.makeFirstResponder(self)
        // A link is followed by a click.
        if event.modifierFlags.contains(.command) || (textStorage.map { start < $0.length && $0.attribute(.link, at: start, effectiveRange: nil) != nil } ?? false) { return super.mouseDown(with: event) }
        setSelectedRange(NSRange(location: start, length: 0))
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            if bounds.contains(point) {
                table.clearSelected()
                let at = characterIndexForInsertion(at: point)
                setSelectedRange(NSRange(location: min(start, at), length: abs(at - start)))
            } else {
                setSelectedRange(NSRange(location: start, length: 0))
                table.select(from: self, to: table.convert(next.locationInWindow, from: nil))
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        if let menu { table?.addItems(to: menu, for: self) }
        return menu
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": toggleWrap("**"); return true
        case "i": toggleWrap("*"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    func toggleWrap(_ marker: String) {
        let range = selectedRange(), text = string as NSString, m = (marker as NSString).length
        let selected = text.substring(with: range)
        if range.location >= m, NSMaxRange(range) + m <= text.length, text.substring(with: NSRange(location: range.location - m, length: m)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(range), length: m)) == marker {
            insertText(selected, replacementRange: NSRange(location: range.location - m, length: range.length + 2 * m))
            setSelectedRange(NSRange(location: range.location - m, length: range.length))
        } else {
            insertText(marker + selected + marker, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + m, length: range.length))
        }
    }
}
