import AppKit

/// The pointer over the edges that can be dragged (the dividers between panes, the floating panel's left edge).
///
/// What lies on both sides of an edge (pages, text, lists) sets the pointer too, with every move of the mouse and in no
/// order to rely on: it flickered, and the resize pointer was hard to get. Here moves over an edge are taken before
/// anything else sees them, over exactly the strip where a press starts the drag.
@MainActor
final class EdgePointer: NSResponder {
    static let shared = EdgePointer()
    /// How far an edge reaches to either side.
    nonisolated static let reach: CGFloat = 5

    private struct Edge {
        weak var view: NSView?
        let strips: () -> [NSRect]
    }

    private var edges: [Edge] = []
    private var monitor: Any?
    private weak var over: NSWindow?

    static var cursor: NSCursor {
        if #available(macOS 15, *) { .columnResize } else { .resizeLeftRight }
    }

    /// `strips`: in the view's coordinates; the view is what a press there goes to.
    func add(_ view: NSView, strips: @escaping () -> [NSRect]) {
        edges.removeAll { $0.view == nil || $0.view === view }
        edges.append(Edge(view: view, strips: strips))
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .cursorUpdate, .mouseEntered, .mouseExited]) { event in
            nonisolated(unsafe) let moved = event
            let passes = MainActor.assumeIsolated { EdgePointer.shared.lets(moved) }
            return passes ? event : nil
        }
    }

    // The tracking areas' owner: what they report is taken by the monitor.
    override func mouseMoved(with event: NSEvent) {}
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {}

    func isOverEdge(_ point: NSPoint, in window: NSWindow) -> Bool {
        edges.contains { edge in
            guard let view = edge.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let local = view.convert(point, from: nil)
            guard edge.strips().contains(where: { $0.contains(local) }), let frame = window.contentView?.superview else { return false }
            // Not where something lies over the edge.
            return frame.hitTest(frame.convert(point, from: nil)) === view
        }
    }

    /// Whether the event goes on to everything else.
    private func lets(_ event: NSEvent) -> Bool {
        guard let window = event.window, NSEvent.pressedMouseButtons == 0 else { return true }
        if isOverEdge(event.locationInWindow, in: window) {
            over = window
            Self.cursor.set()
            // Entering and leaving are for what keeps count of them; what they do to the pointer is undone.
            guard event.type == .mouseMoved || event.type == .cursorUpdate else {
                DispatchQueue.main.async { [weak self] in if self?.over === window { Self.cursor.set() } }
                return true
            }
            return false
        }
        if over != nil, event.type == .mouseMoved {
            over = nil
            // What is under the pointer now may have said what it wants while that was not asked for.
            NSCursor.arrow.set()
            window.resetCursorRects()
        }
        return true
    }
}
