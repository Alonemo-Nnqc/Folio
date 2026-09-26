import AppKit
import SwiftUI

/// Bridges the AppKit sidebar outline into SwiftUI. SwiftUI owns the model; AppKit only renders it.
struct SidebarOutline: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> SidebarController { SidebarController(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = context.coordinator.outline
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Touch the observed state so SwiftUI re-runs this when it changes.
        _ = (model.snapshot, model.counts, model.sidebarSelection, model.groupPendingRename)
        context.coordinator.update()
    }
}
