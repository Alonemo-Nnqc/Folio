import AppKit
import SwiftUI

struct ItemOutline: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> ItemListController { ItemListController(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = context.coordinator.outline
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        _ = (model.rows, model.snapshot, model.selectedItemIDs, model.selectedFileIDs, model.currentSort)
        context.coordinator.update()
    }
}
