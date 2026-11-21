import AppKit

/// The item list's column headers: titles and the sort arrow, with a short rule between two columns and none at the
/// list's edges (before the first column, after the last), so the header reads as one strip across the list.
final class ItemHeaderView: NSTableHeaderView {
    /// Told when the mouse goes down in the header (true) and when it comes back up (false): a column edge may be
    /// dragged in between (AppKit tracks the drag inside `mouseDown`).
    var onDrag: (Bool) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        onDrag(true)
        super.mouseDown(with: event)
        onDrag(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        // While a column is dragged to a new place, AppKit draws the moving column itself.
        guard let table = tableView, draggedColumn < 0 else { return super.draw(dirtyRect) }
        let sort = table.sortDescriptors.first
        for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect), let cell = column.headerCell as? ItemHeaderCell else { continue }
            cell.sortAscending = sort?.key == column.identifier.rawValue ? sort?.ascending : nil
            cell.isPressed = index == resizedColumn ? false : cell.isHighlighted
            cell.draw(withFrame: rect, in: self)
        }
        // The rule under the headers, across the whole list.
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: bounds.width, height: 1).fill()
    }
}

final class ItemHeaderCell: NSTableHeaderCell {
    /// The last visible column: no rule after it.
    var isLast = false
    var sortAscending: Bool?
    var isPressed = false

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        var title = cellFrame.insetBy(dx: 0, dy: 0)
        if let ascending = sortAscending {
            drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: ascending, priority: 0)
            title.size.width -= 16
        }
        // The title, set once as a Core Text line and drawn at the optical centre (AppKit's header cell lays its
        // text out again, font lookup and all, at every redraw).
        let font = self.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let color = textColor ?? .headerTextColor
        let textArea = title.insetBy(dx: 5, dy: 0)
        controlView.effectiveAppearance.performAsCurrentDrawingAppearance {
            CapsuleLabel.drawText(stringValue, in: NSRect(x: textArea.minX, y: title.minY, width: textArea.width, height: title.height),
                                  color: color, font: font, flipped: controlView.isFlipped, scale: controlView.window?.backingScaleFactor ?? 2,
                                  centered: false)
        }
        guard !isLast else { return }
        NSColor.separatorColor.setFill()
        let inset = round(cellFrame.height * 0.25)
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + inset, width: 1, height: cellFrame.height - inset * 2).fill()
    }
}
