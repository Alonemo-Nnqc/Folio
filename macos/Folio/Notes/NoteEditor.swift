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

/// Markdown note of one item (NOTE-01/02): plain text with light syntax colouring, saved 0.8 s after typing stops.
struct NoteEditor: NSViewRepresentable {
    let model: AppModel
    let itemId: String
    /// Bumped by the owner to move keyboard focus into the editor.
    var focusRequest = 0

    func makeCoordinator() -> NoteEditorController { NoteEditorController(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.load(itemId: itemId)
        context.coordinator.focus(request: focusRequest)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: NoteEditorController) {
        coordinator.saveNow()
    }
}

final class NoteEditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let scrollView = NSTextView.scrollableTextView()
    private let model: AppModel
    private var itemId: String?
    private var saveTask: Task<Void, Never>?
    private var isDirty = false
    private var isLoading = false
    private var lastFocusRequest = 0

    var textView: NSTextView { scrollView.documentView as! NSTextView }

    init(model: AppModel) {
        self.model = model
        super.init()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = self.textView
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = MarkdownHighlighter.bodyFont
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.setAccessibilityIdentifier("noteEditor")
        // NSTextView draws this when empty (the same property Notes-style editors use).
        let placeholder = NSAttributedString(string: String(localized: "记下想法、摘录与待办… 支持 Markdown"), attributes: [
            .foregroundColor: NSColor.placeholderTextColor, .font: MarkdownHighlighter.bodyFont])
        if textView.responds(to: Selector(("setPlaceholderAttributedString:"))) {
            textView.setValue(placeholder, forKey: "placeholderAttributedString")
        }
        textView.setAccessibilityLabel(String(localized: "笔记"))
        NotificationCenter.default.addObserver(self, selector: #selector(noteDidChange(_:)), name: .folioNoteDidChange, object: nil)
    }

    @objc private func noteDidChange(_ notification: Notification) {
        guard let id = notification.object as? String, id == itemId, !isDirty else { return }
        reload()
    }

    func load(itemId: String) {
        guard itemId != self.itemId else { return }
        saveNow()
        self.itemId = itemId
        reload()
        textView.undoManager?.removeAllActions()
    }

    private func reload() {
        guard let itemId else { return }
        isLoading = true
        let selection = textView.selectedRanges
        textView.string = (try? model.library.note(for: itemId)) ?? ""
        let length = (textView.string as NSString).length
        textView.selectedRanges = selection.filter { $0.rangeValue.upperBound <= length }.isEmpty
            ? [NSValue(range: NSRange(location: length, length: 0))] : selection
        isLoading = false
    }

    func focus(request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.textView.window?.makeFirstResponder(self.textView)
        }
    }

    // MARK: Saving

    func textDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func textDidEndEditing(_ notification: Notification) { saveNow() }

    func saveNow() {
        saveTask?.cancel()
        guard isDirty, let itemId else { return }
        isDirty = false
        let text = textView.string
        model.perform(String(localized: "无法保存笔记")) { try model.library.setNote(text, for: itemId) }
        NotificationCenter.default.post(name: .folioNoteDidChange, object: itemId)
    }

    // MARK: Highlighting

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Text storage delegates are called on the main thread for views' storages.
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated { MarkdownHighlighter.highlight(storage) }
    }
}

/// Colours Markdown syntax in place without changing the text (NOTE-02).
enum MarkdownHighlighter {
    static let bodyFont = NSFont.systemFont(ofSize: 13)

    private static let rules: [(NSRegularExpression, (NSTextStorage, NSTextCheckingResult) -> Void)] = {
        func regex(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return [
            (regex(#"^(#{1,6})\s+.*$"#), { storage, match in
                let level = storage.attributedSubstring(from: match.range(at: 1)).length
                let size: CGFloat = [20, 17, 15, 14, 13, 13][min(level, 6) - 1]
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: match.range)
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: match.range(at: 1))
            }),
            (regex(#"^>\s?.*$"#), { storage, match in
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: match.range)
                let font = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
                storage.addAttribute(.font, value: font, range: match.range)
            }),
            (regex(#"^\s*([-*+]|\d+\.)\s"#), { storage, match in
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: match.range(at: 1))
            }),
            (regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#), { storage, match in
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold), range: match.range)
            }),
            (regex(#"(?<![*_])([*_])(?=\S)([^*_\n]+?)(?<=\S)\1(?![*_])"#), { storage, match in
                storage.addAttribute(.font, value: NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask),
                                     range: match.range)
            }),
            (regex(#"`[^`\n]+`"#), { storage, match in
                storage.addAttribute(.font, value: mono, range: match.range)
                storage.addAttribute(.backgroundColor, value: NSColor.quaternarySystemFill, range: match.range)
            }),
            (regex(#"\[[^\]\n]+\]\([^)\n]+\)"#), { storage, match in
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: match.range)
            }),
        ]
    }()

    static func highlight(_ storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: storage.length)
        storage.setAttributes([.font: bodyFont, .foregroundColor: NSColor.labelColor], range: whole)
        for (regex, apply) in rules {
            for match in regex.matches(in: storage.string, range: whole) { apply(storage, match) }
        }
    }
}
