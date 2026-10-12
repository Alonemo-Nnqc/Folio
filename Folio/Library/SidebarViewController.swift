import AppKit

/// The source list (SIDE-*). Sections and their + buttons live in the list itself, like Mail and Notes.
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
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = controller.outline
        view = scroll
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
