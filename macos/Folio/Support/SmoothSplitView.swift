import AppKit

/// A side pane's content over its 背景透明度 veil.
final class PaneContainerController: NSViewController {
    enum Edge { case leading, trailing }

    let child: NSViewController
    private let edge: Edge
    let backdrop = TranslucentBackdrop()

    init(child: NSViewController, edge: Edge) {
        self.child = child
        self.edge = edge
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func loadView() {
        let container = NSView()
        container.clipsToBounds = true
        addChild(child)
        let content = child.view
        for view in [backdrop, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
    }

    /// Puts the content (back) into the pane: it is lent to the floating panel meanwhile.
    func takeBack() {
        let content = child.view
        guard content.superview !== view else { return }
        content.removeFromSuperview()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor), content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

/// A split view controller with one frosted layer behind all its panes, that tells its owner when panes start and
/// stop sliding.
class SmoothSplitViewController: NSSplitViewController {
    /// 背景透明度: one frosted layer behind every pane, the size of the window. Panes lay their tinted veils over it
    /// (`TranslucentBackdrop.drawsBlur = false`), so sliding a pane moves only plain colour layers.
    private let windowBlur = NSVisualEffectView()
    /// What the sidebar's glass sits on, as before the blur was shared: the window's own colour.
    private(set) var sidebarUnderlay = PlainColorView()

    var translucency: Double = 0 {
        didSet {
            let active = translucency > 0.001
            windowBlur.isHidden = !active
            sidebarUnderlay.isHidden = !active
            placeSidebarUnderlay()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        windowBlur.material = .underWindowBackground
        windowBlur.blendingMode = .behindWindow
        windowBlur.state = .followsWindowActiveState
        windowBlur.isHidden = true
        sidebarUnderlay.isHidden = true
        // Not arranged by the split view (`arrangesAllSubviews` is off for split view controllers): behind the panes.
        for view in [sidebarUnderlay, windowBlur] as [NSView] {
            view.frame = splitView.bounds
            view.autoresizingMask = [.width, .height]
            splitView.addSubview(view, positioned: .below, relativeTo: nil)
        }
        EdgePointer.shared.add(splitView) { [weak self] in self?.dividerStrips ?? [] }
    }

    /// Where the dividers are dragged: below the toolbar, whose own places move the window.
    private var dividerStrips: [NSRect] {
        let items = splitViewItems
        guard items.count > 1, let window = view.window else { return [] }
        let top = splitView.convert(NSPoint(x: 0, y: window.contentLayoutRect.maxY), from: nil).y
        return items.indices.dropLast().compactMap { index in
            guard !items[index].isCollapsed, !items[index + 1].isCollapsed, floatingInspector == nil || index != items.count - 2 else { return nil }
            let left = splitView.arrangedSubviews[index], right = splitView.arrangedSubviews[index + 1]
            // (The content goes on under a floating pane: the edge is the pane's.)
            let x = items[index + 1].behavior == .inspector ? right.frame.minX : left.frame.maxX
            let strip = NSRect(x: x - EdgePointer.reach, y: 0, width: EdgePointer.reach * 2 + 1, height: splitView.bounds.height)
            return splitView.isFlipped ? strip.intersection(NSRect(x: 0, y: top, width: splitView.bounds.width, height: splitView.bounds.height - top))
                : strip.intersection(NSRect(x: 0, y: 0, width: splitView.bounds.width, height: top))
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        followContentEdge()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        followContentEdge()
    }

    private var observedContent: NSView?

    /// The underlay reaches exactly to the content's left edge at every frame of a slide (it used to take the
    /// sidebar's final width at the first frame: a block of window colour showed under the list before the sidebar
    /// arrived, and vanished while it was still leaving).
    private func followContentEdge() {
        guard let content = splitViewItems.first(where: { $0.behavior != .sidebar && $0.behavior != .inspector })?.viewController.view else { return }
        if observedContent !== content {
            observedContent = content
            content.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: content, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeSidebarUnderlay() }
            }
        }
        placeSidebarUnderlay()
    }

    private func placeSidebarUnderlay() {
        guard !sidebarUnderlay.isHidden, let content = observedContent else { return }
        // The content's edge in the split view's coordinates (it may sit in a wrapper of AppKit's).
        let edge = content.convert(content.bounds, to: splitView).minX
        sidebarUnderlay.autoresizingMask = [.height]
        let frame = NSRect(x: 0, y: 0, width: max(edge, 0), height: splitView.bounds.height)
        if sidebarUnderlay.frame != frame { sidebarUnderlay.frame = frame }
    }

    /// Told when a pane starts and stops sliding (the reader holds the PDF's scale meanwhile).
    var onAnimationBegan: () -> Void = {}
    var onAnimationEnded: () -> Void = {}
    private var running = 0

    override func toggleSidebar(_ sender: Any?) {
        guard let item = splitViewItems.first(where: { $0.behavior == .sidebar }) else { return super.toggleSidebar(sender) }
        setCollapsed(item, !item.isCollapsed)
    }

    override func toggleInspector(_ sender: Any?) {
        guard inspectorSplitItem != nil else { return super.toggleInspector(sender) }
        setInspectorOpen(!isInspectorOpen)
    }

    // MARK: The right panel, beside the content or floating over it

    private var inspectorSplitItem: NSSplitViewItem? { splitViewItems.last(where: { $0.behavior == .inspector }) }
    private(set) var floatingInspector: FloatingInspector?
    /// Set by the owner from 设置 ▸ 通用 ▸ 右侧栏样式.
    var floatsInspector = false { didSet { if floatsInspector != oldValue { applyInspectorStyle() } } }
    /// Told when the panel opens or closes in its floating style (beside the content, its split item says so).
    var onFloatingInspectorChanged: () -> Void = {}
    /// Puts into a new floating panel's header what the toolbar has over the panel beside the content.
    var onFloatingInspectorMade: (FloatingInspector) -> Void = { _ in }
    private var floatingOpenKey: String? {
        guard !UserDefaults.standard.bool(forKey: "FolioUITesting") else { return nil }
        return splitView.autosaveName.map { "floatingInspectorOpen." + $0 }
    }

    var isInspectorOpen: Bool { floatingInspector?.isOpen ?? !(inspectorSplitItem?.isCollapsed ?? true) }

    func setInspectorOpen(_ open: Bool) {
        if let floatingInspector {
            floatingInspector.setOpen(open, animated: true)
            if let floatingOpenKey { UserDefaults.standard.set(open, forKey: floatingOpenKey) }
            onFloatingInspectorChanged()
        } else if let item = inspectorSplitItem {
            setCollapsed(item, !open)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The saved layout is restored by now: the pane under a floating panel stays closed.
        if floatsInspector, floatingInspector == nil { applyInspectorStyle() }
        if floatingInspector != nil { inspectorSplitItem?.isCollapsed = true }
    }

    private func applyInspectorStyle() {
        guard isViewLoaded, let item = inspectorSplitItem, let pane = item.viewController as? PaneContainerController else { return }
        let open = isInspectorOpen
        if floatsInspector {
            // Over the toolbar too: in the window's frame, above what AppKit has there. (Until there is a window: later.)
            guard floatingInspector == nil, let frame = view.window?.contentView?.superview else { return }
            let panel = FloatingInspector(in: frame)
            panel.onClose = { [weak self] in self?.setInspectorOpen(false) }
            panel.hold(pane.child.view)
            onFloatingInspectorMade(panel)
            floatingInspector = panel
            item.isCollapsed = true
            let saved = floatingOpenKey.flatMap { UserDefaults.standard.object(forKey: $0) as? Bool }
            // Chosen just now, it stays as it is; at launch it is as it was left.
            panel.setOpen(view.window?.isVisible == true ? open : saved ?? open, animated: false)
        } else if let panel = floatingInspector {
            floatingInspector = nil
            pane.takeBack()
            panel.removeFromSuperview()
            item.isCollapsed = !open
        }
        onFloatingInspectorChanged()
    }

    /// Nothing to drag at the window's edge while the pane there is the floating one's.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        if floatingInspector != nil, dividerIndex == splitViewItems.count - 2 { return .zero }
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        guard !rect.isEmpty else { return rect }
        // Enough to be found at once, the same to either side.
        return NSRect(x: drawnRect.midX - EdgePointer.reach - 0.5, y: rect.minY, width: EdgePointer.reach * 2 + 1, height: rect.height)
    }

    /// Opens or closes a pane with AppKit's own slide (its timing, and the glass of a sidebar moving with it, as in
    /// Finder and Mail); only told before and after.
    func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool) {
        guard item.isCollapsed != collapsed else { return }
        guard view.window?.isVisible == true else {
            item.isCollapsed = collapsed
            return
        }
        running += 1
        if running == 1 { onAnimationBegan() }
        NSAnimationContext.runAnimationGroup({ _ in
            item.animator().isCollapsed = collapsed
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.running -= 1
            if self.running == 0 { self.onAnimationEnded() }
        })
    }
}

/// A plain layer in the window's background colour.
final class PlainColorView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
