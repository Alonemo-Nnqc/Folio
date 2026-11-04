import AppKit

/// `-FolioPreviewSimulateDrop <file>` runs the list's real drop code (validateDrop → acceptDrop)
/// with a pasteboard holding that file URL — the same calls AppKit makes when a file is dropped
/// from Finder — and writes the outcome to `-FolioSimulateDropLog <file>`. No input events involved.
enum SimulatedDrop {
    static func run(path: String, model: AppModel, attempt: Int = 0) {
        if let groupName = UserDefaults.standard.string(forKey: "FolioSimulateDropGroup") {
            return runOnSidebar(path: path, groupName: groupName, model: model)
        }
        guard let controller = model.itemListController else {
            // The list may not exist yet right after launch; try again shortly.
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { run(path: path, model: model, attempt: attempt + 1) }
            } else if let log = UserDefaults.standard.string(forKey: "FolioSimulateDropLog") {
                append("no item list controller\n", to: log)
            }
            return
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.nnqc.folio.simulated-drop"))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(filePath: path) as NSURL])
        let info = FakeDraggingInfo(pasteboard: pasteboard)
        let operation = controller.outlineView(controller.outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 0)
        let overlay = model.externalDropCount
        let accepted = operation.isEmpty ? false
            : controller.outlineView(controller.outline, acceptDrop: info, item: nil, childIndex: NSOutlineViewDropOnItemIndex)
        // AppKit ends every session with these callbacks; they must not raise.
        controller.outline.draggingExited(info)
        controller.outline.draggingEnded(info)
        let line = "validate=\(operation.rawValue) overlayCount=\(overlay) accepted=\(accepted) overlayAfter=\(model.externalDropCount)\n"
        if let log = UserDefaults.standard.string(forKey: "FolioSimulateDropLog") {
            append(line, to: log)
        }
    }

    static func append(_ line: String, to log: String) {
        if let handle = FileHandle(forWritingAtPath: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: log, atomically: true, encoding: .utf8)
        }
    }
}

extension SimulatedDrop {
    /// `-FolioSimulateDropGroup <name>`: drop the file onto that sidebar group instead (DND-02).
    static func runOnSidebar(path: String, groupName: String, model: AppModel) {
        guard let sidebar = model.sidebarController, let node = sidebar.node(forGroupNamed: groupName) else { return }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.nnqc.folio.simulated-drop"))
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(filePath: path) as NSURL])
        let info = FakeDraggingInfo(pasteboard: pasteboard)
        let operation = sidebar.outlineView(sidebar.outline, validateDrop: info, proposedItem: node,
                                            proposedChildIndex: NSOutlineViewDropOnItemIndex)
        let accepted = operation.isEmpty ? false
            : sidebar.outlineView(sidebar.outline, acceptDrop: info, item: node, childIndex: NSOutlineViewDropOnItemIndex)
        if let log = UserDefaults.standard.string(forKey: "FolioSimulateDropLog") {
            append("sidebar validate=\(operation.rawValue) accepted=\(accepted)\n", to: log)
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
