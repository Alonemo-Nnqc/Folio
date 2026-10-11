import AppKit

/// The source list (SIDE-*) with a "新建分组" button at the bottom, like Notes and Mail.
final class SidebarViewController: NSViewController {
    let controller: SidebarController
    private let model: AppModel
    private var observer: ObservationLoop?

    init(model: AppModel) {
        self.model = model
        controller = SidebarController(model: model)
        super.init(nibName: nil, bundle: nil)
        model.sidebarController = controller
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func loadView() {
        let root = NSView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = controller.outline

        let add = NSButton(title: "新建分组", image: NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil)!,
                           target: nil, action: #selector(LibraryWindowController.newGroup(_:)))
        add.bezelStyle = .accessoryBarAction
        add.isBordered = false
        add.imagePosition = .imageLeading
        add.contentTintColor = .secondaryLabelColor
        add.font = .systemFont(ofSize: NSFont.systemFontSize)
        add.toolTip = "新建分组（⇧⌘N）"
        add.setAccessibilityIdentifier("newGroupButton")

        for view in [scroll, add] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -4),
            add.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            add.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = ObservationLoop { [weak self] in
            guard let self else { return }
            _ = (self.model.snapshot, self.model.counts, self.model.sidebarSelection, self.model.groupPendingRename,
                 self.model.previewExpandAllGroups)
            self.controller.update()
        }
    }
}
