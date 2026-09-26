import AppKit
import SwiftUI

/// A native NSSearchField that reports text changes and Esc (SEARCH-01).
struct SidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "搜索文献"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.controlSize = .large
        field.setAccessibilityIdentifier("sidebarSearchField")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SidebarSearchField
        var lastFocusRequest = -1

        init(_ parent: SidebarSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            if (control as? NSSearchField)?.stringValue.isEmpty ?? true { parent.onCancel() }
            else { parent.text = "" }
            return true
        }
    }
}
