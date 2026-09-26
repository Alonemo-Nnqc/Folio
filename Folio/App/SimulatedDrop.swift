import AppKit

/// `-FolioPreviewSimulateDrop <file>` runs the list's real drop code (validateDrop → acceptDrop)
/// with a pasteboard holding that file URL — the same calls AppKit makes when a file is dropped
/// from Finder — and writes the outcome to `-FolioSimulateDropLog <file>`. No input events involved.
enum SimulatedDrop {
    static func run(path: String, model: AppModel) {
        guard let controller = model.itemListController else { return }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.nnqc.folio.simulated-drop"))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(filePath: path) as NSURL])
        let info = FakeDraggingInfo(pasteboard: pasteboard)
        let operation = controller.outlineView(controller.outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 0)
        let overlay = model.externalDropCount
        let accepted = operation.isEmpty ? false
            : controller.outlineView(controller.outline, acceptDrop: info, item: nil, childIndex: NSOutlineViewDropOnItemIndex)
        let line = "validate=\(operation.rawValue) overlayCount=\(overlay) accepted=\(accepted) overlayAfter=\(model.externalDropCount)\n"
        if let log = UserDefaults.standard.string(forKey: "FolioSimulateDropLog") {
            try? line.write(toFile: log, atomically: true, encoding: .utf8)
        }
    }
}

/// Minimal NSDraggingInfo for a drag coming from another app (no dragging source in this process).
final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { NSApp.windows.first }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .link, .generic] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
