import AppKit

/// A side pane's content in a box of its own. While the pane slides open or closed its content keeps its width and is
/// uncovered or covered from the window's edge, instead of being laid out again at every frame of the animation —
/// what made the sidebars stutter, especially SwiftUI ones (thumbnails, the inspector's forms).
final class PaneContainerController: NSViewController {
    enum Edge { case leading, trailing }

    let child: NSViewController
    private let edge: Edge
    private var fill: NSLayoutConstraint!
    private var fixed: NSLayoutConstraint!
    private(set) var lastWidth: CGFloat = 0
    private var frozen = false
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
        fill = content.widthAnchor.constraint(equalTo: container.widthAnchor)
        fixed = content.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            edge == .leading ? content.leadingAnchor.constraint(equalTo: container.leadingAnchor)
                             : content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fill,
        ])
        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !frozen, view.bounds.width > 1 { lastWidth = view.bounds.width }
    }

    /// Holds the content at its open width until `thaw()`. `minimum`: the width when it was never open.
    func freeze(minimum: CGFloat) {
        guard !frozen else { return }
        frozen = true
        fixed.constant = max(lastWidth, view.bounds.width, minimum)
        fill.isActive = false
        fixed.isActive = true
    }

    func thaw() {
        guard frozen else { return }
        frozen = false
        fixed.isActive = false
        fill.isActive = true
    }
}

/// A split view controller whose sidebar and inspector slide smoothly (see `PaneContainerController`), and that tells
/// its owner when panes start and stop moving (the reader holds the PDF's scale meanwhile).
class SmoothSplitViewController: NSSplitViewController {
    var onAnimationBegan: () -> Void = {}
    var onAnimationEnded: () -> Void = {}
    private var running = 0

    static let duration: TimeInterval = 0.26

    override func toggleSidebar(_ sender: Any?) {
        guard let item = splitViewItems.first(where: { $0.behavior == .sidebar }) else { return super.toggleSidebar(sender) }
        setCollapsed(item, !item.isCollapsed)
    }

    override func toggleInspector(_ sender: Any?) {
        guard let item = splitViewItems.last(where: { $0.behavior == .inspector }) else { return super.toggleInspector(sender) }
        setCollapsed(item, !item.isCollapsed)
    }

    /// Opens or closes a pane with the animation.
    func setCollapsed(_ item: NSSplitViewItem, _ collapsed: Bool) {
        guard item.isCollapsed != collapsed else { return }
        guard view.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            item.isCollapsed = collapsed
            return
        }
        let panes = splitViewItems.compactMap { side -> (PaneContainerController, CGFloat)? in
            guard let pane = side.viewController as? PaneContainerController else { return nil }
            return (pane, side.minimumThickness)
        }
        panes.forEach { $0.0.freeze(minimum: $0.1) }
        running += 1
        if running == 1 { onAnimationBegan() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            context.allowsImplicitAnimation = true
            item.animator().isCollapsed = collapsed
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.running -= 1
            guard self.running == 0 else { return }
            panes.forEach { $0.0.thaw() }
            self.onAnimationEnded()
        })
    }
}
