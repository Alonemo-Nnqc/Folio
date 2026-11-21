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
        guard let item = splitViewItems.last(where: { $0.behavior == .inspector }) else { return super.toggleInspector(sender) }
        setCollapsed(item, !item.isCollapsed)
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
