import AppKit
import SwiftUI

/// The source list (SIDE-*). Sections and their + buttons live in the list itself, like Mail and Notes.
final class SidebarViewController: NSViewController {
    let controller: SidebarController
    private let model: AppModel
    private var observer: ObservationLoop?
    private var updateObserver: ObservationLoop?

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
        // An update waiting: a small card at the sidebar's foot (the list makes room for it).
        let pill = NSHostingView(rootView: UpdatePill(updater: AppDelegate.shared.updater))
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.sizingOptions = [.intrinsicContentSize]
        let container = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)
        container.addSubview(pill)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            pill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            pill.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = ObservationLoop { [weak self] in
            guard let self else { return }
            _ = (self.model.snapshot, self.model.counts, self.model.sidebarSelection, self.model.groupPendingRename,
                 self.model.previewExpandAllGroups)
            self.controller.update()
        }
        updateObserver = ObservationLoop { [weak self] in
            let waiting = AppDelegate.shared.updater.pendingUpdate != nil
            self?.view.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 0, bottom: waiting ? 54 : 0, right: 0)
        }
    }
}
