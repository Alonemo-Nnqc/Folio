import AppKit

/// The right panel in its floating style (设置 ▸ 通用 ▸ 右侧栏样式): a sheet of glass against the window's right
/// edge, from its top (over the toolbar too) to its bottom, its left corners round as the window's own are; what is under
/// it keeps its width. Its left edge is dragged to make it wider, up to most of the window.
final class FloatingInspector: NSView {
    static let minimumWidth: CGFloat = 280
    private static let widthKey = "floatingInspectorWidth"
    /// The corners of a window with a toolbar.
    static var cornerRadius: CGFloat {
        if #available(macOS 27, *) { 16 } else if #available(macOS 26, *) { 26 } else { 10 }
    }
    private let contentHolder = GlassVeil()
    private let grip = FloatingInspectorGrip()
    private var glass: NSView!
    private var width: NSLayoutConstraint!
    private var trailing: NSLayoutConstraint!
    private(set) var isOpen = false
    /// The panel's own button closes it: the toolbar's is under it.
    var onClose: () -> Void = {}
    /// The toolbar's row: what the toolbar has over the panel beside the content is here in the same places.
    static let headerHeight: CGFloat = 52
    private static let itemSide: CGFloat = 36
    private static let itemInset: CGFloat = 8

    /// A control as the toolbar shows one: on a capsule of glass.
    static func toolbarItem(_ control: NSView, fixedWidth: CGFloat? = nil) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        let holder = ToolbarItemContent()
        holder.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: holder.centerXAnchor), control.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            fixedWidth.map { holder.widthAnchor.constraint(equalToConstant: $0) } ?? holder.widthAnchor.constraint(equalTo: control.widthAnchor),
            holder.heightAnchor.constraint(equalToConstant: itemSide),
        ])
        var item: NSView = holder
        if !UserDefaults.standard.bool(forKey: "FolioPreviewNoGlass"), #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = itemSide / 2
            glass.contentView = holder
            item = glass
        } else {
            holder.wantsLayer = true
            holder.layer?.cornerRadius = itemSide / 2
            holder.layer?.borderWidth = 0.5
            holder.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        item.translatesAutoresizingMaskIntoConstraints = false
        return item
    }

    /// Tabs as the toolbar draws them: text on the glass itself, the chosen one on a capsule.
    static func toolbarTabs(_ titles: [String], target: AnyObject?, action: Selector) -> NSSegmentedControl {
        let control = ToolbarTabs(labels: titles, trackingMode: .selectOne, target: target, action: action)
        control.setAccessibilityIdentifier("inspectorTabs")
        for index in titles.indices { control.setWidth(ToolbarTabsCell.pitch, forSegment: index) }
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalToConstant: CGFloat(titles.count) * ToolbarTabsCell.pitch + 3).isActive = true
        control.heightAnchor.constraint(equalToConstant: itemSide).isActive = true
        return control
    }

    static func iconButton(_ symbol: String, _ label: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: target, action: action)
        button.isBordered = false
        button.symbolConfiguration = .init(pointSize: 16, weight: .medium)
        button.contentTintColor = .labelColor
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private var closeItem: NSView!

    /// What the toolbar has over the panel: in its middle (tabs), or at its start and before the panel's button.
    func setHeader(leading: NSView? = nil, center: NSView? = nil, trailing: NSView? = nil) {
        for view in [leading, center, trailing].compactMap({ $0 }) {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: closeItem.centerYAnchor).isActive = true
        }
        leading?.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12).isActive = true
        trailing?.trailingAnchor.constraint(equalTo: closeItem.leadingAnchor, constant: -8).isActive = true
        if let center {
            let room = NSLayoutGuide()
            addLayoutGuide(room)
            NSLayoutConstraint.activate([room.leadingAnchor.constraint(equalTo: leadingAnchor), room.trailingAnchor.constraint(equalTo: closeItem.leadingAnchor),
                                         center.centerXAnchor.constraint(equalTo: room.centerXAnchor)])
        }
    }

    init(in parent: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        contentHolder.clipsToBounds = true
        contentHolder.wantsLayer = true
        // Snapshots cannot draw glass.
        if !UserDefaults.standard.bool(forKey: "FolioPreviewNoGlass"), #available(macOS 26, *) {
            let view = NSGlassEffectView()
            view.cornerRadius = Self.cornerRadius
            view.contentView = contentHolder
            glass = view
        } else {
            let view = NSVisualEffectView()
            view.material = .popover
            view.blendingMode = .withinWindow
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = Self.cornerRadius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
            contentHolder.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(contentHolder)
            NSLayoutConstraint.activate(Self.fill(contentHolder, view))
            glass = view
        }
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        grip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grip)
        let edge = FloatingInspectorEdge()
        let closeButton = Self.iconButton("sidebar.trailing", String(localized: "隐藏右侧栏"), target: self, action: #selector(closeClicked))
        let close = Self.toolbarItem(closeButton, fixedWidth: Self.itemSide)
        closeItem = close
        closeButton.setAccessibilityIdentifier("closeFloatingInspector")
        for view in [edge, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.itemInset), close.topAnchor.constraint(equalTo: topAnchor, constant: Self.itemInset),
        ])
        parent.addSubview(self, positioned: .above, relativeTo: nil)
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
        width = widthAnchor.constraint(equalToConstant: saved > 0 ? saved : 340)
        width.priority = .defaultHigh
        trailing = trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        // Past the window's edge, which cuts it off there as it does everything: only its left corners are its own.
        NSLayoutConstraint.activate(Self.fill(edge, glass) + [
            glass.topAnchor.constraint(equalTo: topAnchor), glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor, constant: Self.cornerRadius * 2),
            width, trailing,
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            // The content stays in sight beside it.
            widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor, multiplier: 0.8),
            topAnchor.constraint(equalTo: parent.topAnchor),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -EdgePointer.reach),
            grip.widthAnchor.constraint(equalToConstant: EdgePointer.reach * 2 + 1),
            grip.topAnchor.constraint(equalTo: topAnchor),
            grip.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        grip.onDrag = { [weak self] delta, ended in
            guard let self else { return }
            let limit = (self.superview?.bounds.width ?? 1000) * 0.8
            self.width.constant = min(max(self.frame.width - delta, Self.minimumWidth), limit)
            if ended, !UserDefaults.standard.bool(forKey: "FolioUITesting") { UserDefaults.standard.set(Double(self.width.constant), forKey: Self.widthKey) }
        }
        isHidden = true
        setAccessibilityIdentifier("floatingInspector")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private static func fill(_ view: NSView, _ other: NSView) -> [NSLayoutConstraint] {
        [view.topAnchor.constraint(equalTo: other.topAnchor), view.bottomAnchor.constraint(equalTo: other.bottomAnchor),
         view.leadingAnchor.constraint(equalTo: other.leadingAnchor), view.trailingAnchor.constraint(equalTo: other.trailingAnchor)]
    }

    func hold(_ content: NSView) {
        content.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        contentHolder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentHolder.topAnchor, constant: Self.headerHeight),
            content.bottomAnchor.constraint(equalTo: contentHolder.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: contentHolder.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentHolder.trailingAnchor, constant: -Self.cornerRadius * 2),
        ])
    }

    @objc private func closeClicked() { onClose() }

    func setWidth(_ value: CGFloat) { width.constant = value }

    func setOpen(_ open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        // What was being written in it is done.
        if !open, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) { window?.makeFirstResponder(nil) }
        let hidden = width.constant * 0.25
        guard animated, window?.isVisible == true else {
            trailing.constant = 0
            alphaValue = 1
            isHidden = !open
            return
        }
        if open {
            isHidden = false
            alphaValue = 0
            trailing.constant = hidden
            superview?.layoutSubtreeIfNeeded()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = open ? 1 : 0
            trailing.animator().constant = open ? 0 : hidden
        }, completionHandler: { [weak self] in
            guard let self, !self.isOpen else { return }
            self.isHidden = true
        })
    }

    // What is under the panel is not reached through it.
    // Its top row moves the window, as the toolbar under it would.
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y > bounds.height - Self.headerHeight { window?.performDrag(with: event) }
    }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The edge is before everything at it, on the half outside the panel too.
        if !isHidden, let superview, grip.frame.contains(convert(point, from: superview)) { return grip }
        if let hit = super.hitTest(point) { return hit }
        return !isHidden && frame.contains(point) ? self : nil
    }
}

/// A thin layer of the window's colour over the glass: what is under it shows through, the words on it stay readable.
private final class GlassVeil: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor
        }
    }
}

/// The line along the panel's left side, round its corners.
private final class FloatingInspectorEdge: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = FloatingInspector.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// (A control: over the toolbar a press on anything else moves the window.)
private final class FloatingInspectorGrip: NSControl {
    var onDrag: (CGFloat, Bool) -> Void = { _, _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        EdgePointer.shared.add(self) { [weak self] in self.map { [$0.bounds] } ?? [] }
        setAccessibilityIdentifier("floatingInspectorEdge")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        var last = event.locationInWindow.x
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            EdgePointer.cursor.set()
            let x = next.locationInWindow.x
            onDrag(x - last, next.type == .leftMouseUp)
            superview?.superview?.layoutSubtreeIfNeeded()
            last = x
            if next.type == .leftMouseUp { return }
        }
    }
}

/// Dims with its window, as the toolbar's own controls do.
private final class ToolbarItemContent: NSView {
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        observers = [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dim() }
            }
        }
        dim()
    }

    private func dim() { subviews.forEach { $0.alphaValue = window?.isMainWindow == true ? 1 : 0.5 } }
}

private final class ToolbarTabs: NSSegmentedControl {
    override class var cellClass: AnyClass? {
        get { ToolbarTabsCell.self }
        set {}
    }

    override func mouseDown(with event: NSEvent) {
        // The segments as drawn, rather than as AppKit's own bezel would have them.
        let point = convert(event.locationInWindow, from: nil)
        let index = Int((point.x - 1) / ToolbarTabsCell.pitch)
        guard bounds.contains(point), index >= 0, index < segmentCount, index != selectedSegment else { return }
        selectedSegment = index
        needsDisplay = true
        sendAction(action, to: target)
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

private final class ToolbarTabsCell: NSSegmentedCell {
    static let pitch: CGFloat = 57

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let dark = controlView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        for index in 0..<segmentCount {
            let pill = NSRect(x: cellFrame.minX + 4 + CGFloat(index) * Self.pitch, y: cellFrame.midY - 14, width: Self.pitch - 5, height: 28)
            if index == selectedSegment {
                (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 14, yRadius: 14).fill()
            }
            let text = NSAttributedString(string: label(forSegment: index) ?? "", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor])
            let size = text.size()
            text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
        }
    }
}
