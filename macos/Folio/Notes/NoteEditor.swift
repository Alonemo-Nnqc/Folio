import AppKit
import FolioCore
import SwiftUI

extension Notification.Name {
    /// Posted after a note is saved; `object` is the item id. Other editors showing that note reload.
    static let folioNoteDidChange = Notification.Name("FolioNoteDidChange")
}

extension AppModel {
    /// Appends a block to an item's note (READER-08 "添加到笔记") and tells open editors.
    func appendToNote(itemId: String, _ block: String) {
        perform(String(localized: "无法保存笔记")) {
            let current = try library.note(for: itemId)
            let separator = current.isEmpty || current.hasSuffix("\n\n") ? "" : current.hasSuffix("\n") ? "\n" : "\n\n"
            try library.setNote(current + separator + block + "\n", for: itemId)
            NotificationCenter.default.post(name: .folioNoteDidChange, object: itemId)
            toasts.show(String(localized: "已添加到笔记"), systemImage: "note.text.badge.plus")
        }
    }
}

/// Markdown note of one item (NOTE-01/02): edited in place with a live preview (see `MarkdownEditorController`),
/// saved 0.8 s after typing stops.
struct NoteEditor: NSViewRepresentable {
    let model: AppModel
    let itemId: String
    /// Bumped by the owner to move keyboard focus into the editor.
    var focusRequest = 0

    func makeCoordinator() -> MarkdownEditorController { MarkdownEditorController() }

    func makeNSView(context: Context) -> MarkdownPane { MarkdownPane(editor: context.coordinator) }

    func updateNSView(_ nsView: MarkdownPane, context: Context) {
        let model = self.model, itemId = self.itemId
        nsView.showsToolbar = model.settings.markdownToolbar
        context.coordinator.textView.references = { [weak model] in model?.markdownReferences(matching: $0) ?? [] }
        context.coordinator.load(MarkdownSource(
            key: itemId,
            load: { (try? model.library.note(for: itemId)) ?? "" },
            save: { text in model.perform(String(localized: "无法保存笔记")) { try model.library.setNote(text, for: itemId) } },
            notification: .folioNoteDidChange))
        context.coordinator.focus(request: focusRequest)
    }

    static func dismantleNSView(_ nsView: MarkdownPane, coordinator: MarkdownEditorController) {
        coordinator.saveNow()
    }
}
