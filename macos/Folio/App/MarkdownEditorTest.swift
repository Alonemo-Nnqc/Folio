import AppKit

/// `-FolioMarkdownGeometryTest <log>`: in every kind of line, at the start, in the middle and at the end of a document,
/// empty and written in: the caret, the mark before the line, its placeholder and its text are on one line, and nothing
/// moves when the first character is typed.
/// `-FolioMarkdownSequenceTest <log>`: what is typed line after line (Return, leaving a list or quote, Backspace): the caret
/// that blinks is where the next character comes, composed with an input method or not, at every size and spacing.
/// `-FolioMarkdownZoomTest <log>`: at every zoom the whole page is that much larger (text, headings, tables, the column),
/// the text goes on to the edge of the window, the caret is where it was; pictures of it beside the log.
/// `-FolioMarkdownFuzzTest <log>`: many random edits; after each the caret is somewhere it can be, the text is styled as
/// it would be afresh, tables and headers stand where their lines are, and undoing everything gives the text back.
@MainActor
enum MarkdownEditorTest {
    static func run(_ controller: MarkdownWindowController) {
        let defaults = UserDefaults.standard
        if let log = defaults.string(forKey: "FolioMarkdownGeometryTest") { geometry(controller, log: log) }
        if let log = defaults.string(forKey: "FolioMarkdownSequenceTest") { sequences(controller, log: log) }
        if let log = defaults.string(forKey: "FolioMarkdownZoomTest") { zoom(controller, log: log) }
        if let log = defaults.string(forKey: "FolioMarkdownFuzzTest") { fuzz(controller, log: log) }
    }

    private static func set(_ view: MarkdownTextView, _ text: String, caret: Int? = nil) {
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        view.insertText(text, replacementRange: view.selectedRange())
        view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
    }

    /// Where the caret is drawn (view coordinates).
    private static func caretRect(_ view: MarkdownTextView) -> NSRect {
        guard let window = view.window else { return .zero }
        let rect = view.firstRect(forCharacterRange: NSRange(location: view.selectedRange().location, length: 0), actualRange: nil)
        return view.convert(window.convertFromScreen(rect), from: nil)
    }

    private static func baseline(_ view: MarkdownTextView, at location: Int) -> (x: CGFloat, y: CGFloat, line: NSRect) {
        let layout = view.layoutManager!, origin = view.textContainerOrigin
        let glyph = layout.glyphIndexForCharacter(at: location)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let point = layout.location(forGlyphAt: glyph)
        return (origin.x + fragment.minX + point.x, origin.y + fragment.minY + point.y, fragment.offsetBy(dx: origin.x, dy: origin.y))
    }

    private static func bottomOfText(_ layout: NSLayoutManager) -> CGFloat {
        if !layout.extraLineFragmentRect.isEmpty { return layout.extraLineFragmentRect.maxY }
        return layout.numberOfGlyphs > 0 ? layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil).maxY : 0
    }

    private static func zoom(_ controller: MarkdownWindowController, log: String) {
        let view = controller.editor.textView, editor = controller.editor, scroll = editor.scrollView
        var lines: [String] = [], failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1 }; lines.append((ok ? "ok " : "FAIL ") + what) }
        let filler = (1...40).map { "第\($0)段：放大时整页一起变大，文字、间距、表格和图片都按同样的比例。" }.joined(separator: "\n\n")
        set(view, "# 标题一\n\n正文 **粗体** 和 `代码`。\n\n- 列表\n  - 下级\n- [ ] 任务\n\n> 引用\n\n| 甲 | 乙 |\n| --- | --- |\n| 一 | 二 |\n\n```swift\nlet a = 1\n```\n\n" + filler, caret: 2)
        func inWindow(_ rect: NSRect) -> NSRect { view.convert(rect, to: nil) }
        func heights() -> [CGFloat] {
            guard let layout = view.layoutManager else { return [] }
            layout.ensureLayout(for: view.textContainer!)
            let text = view.string as NSString
            return ["标题一", "正文", "列表", "引用", "let a"].map { word in
                inWindow(layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: text.range(of: word).location), effectiveRange: nil)).height
            } + [inWindow(view.blockViews.tables.first?.frame ?? .zero).height, inWindow(view.blockViews.tables.first?.frame ?? .zero).width]
        }
        editor.setZoom(1, at: nil)
        let one = heights()
        for zoom in [0.5, 0.75, 1.25, 2.0, 3.0, 1.0] {
            editor.setZoom(zoom, at: nil)
            view.layoutSubtreeIfNeeded()
            check(abs(scroll.magnification - zoom) < 0.001, "magnification \(zoom)")
            check(abs(view.frame.width - scroll.contentView.bounds.width) < 1, "\(zoom): as wide as the window (\(view.frame.width) of \(scroll.contentView.bounds.width))")
            let now = heights()
            for (k, (a, b)) in zip(one, now).enumerated() where k < 6 { check(abs(b / a - zoom) < zoom * 0.04, "\(zoom): height \(k) \(a) → \(b)") }
            check(view.minSize.height >= scroll.contentView.bounds.height - 1, "\(zoom): the page fills the window")
            if let image = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
                scroll.cacheDisplay(in: scroll.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log + "-\(Int(zoom * 100)).png"))
            }
        }
        // The line under the pointer stays under it.
        let layout = view.layoutManager!, text = view.string as NSString
        let place = text.range(of: "第20段").location
        for zoom in [1.5, 0.6, 2.6] {
            editor.setZoom(1, at: nil)
            view.scrollRangeToVisible(NSRange(location: place, length: 1))
            func y() -> CGFloat { view.convert(layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: place), effectiveRange: nil).offsetBy(dx: 0, dy: view.textContainerOrigin.y), to: nil).midY }
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: place), effectiveRange: nil)
            let before = y()
            editor.setZoom(zoom, at: NSPoint(x: rect.minX + view.textContainerOrigin.x + 6, y: rect.midY + view.textContainerOrigin.y))
            check(abs(y() - before) < 12, "\(zoom): stays under the pointer (\(before) → \(y())), \(view.textContainer!.size.width) wide, \(view.frame.height) high, at \(scroll.contentView.bounds)")
        }
        view.zoomIn(nil)
        view.actualSize(nil)
        check(abs(scroll.magnification - 1) < 0.001 && MarkdownPreferences.current.zoom == 1, "actual size")
        view.zoomIn(nil)
        check(abs(MarkdownPreferences.current.zoom - 1.1) < 0.001, "one step in: \(MarkdownPreferences.current.zoom)")
        view.actualSize(nil)
        panel(controller, view.string, check, log: log)
        lines.append(failures == 0 ? "PASS" : "FAIL \(failures)")
        SimulatedDrop.append(lines.joined(separator: "\n") + "\n", to: log)
    }

    /// A side panel of any width, pinched a little at a time, and dragged wider while it is zoomed.
    private static func panel(_ controller: MarkdownWindowController, _ text: String, _ check: (Bool, String) -> Void, log: String) {
        guard let host = controller.window?.contentView else { return }
        let pane = MarkdownPane(editor: MarkdownEditorController())
        host.addSubview(pane)
        defer { pane.removeFromSuperview() }
        let editor = pane.editor, view = editor.textView, scroll = editor.scrollView
        host.layoutSubtreeIfNeeded()
        set(view, text, caret: 2)
        for width in [280, 340, 420, 620, 1000] as [CGFloat] {
            pane.frame = NSRect(x: 0, y: 0, width: width, height: 620)
            pane.layoutSubtreeIfNeeded()
            check(abs(pane.toolsFrame.midX - width / 2) <= 1 && pane.toolsFrame.minX >= 4, "panel \(width): the tools in its middle (\(pane.toolsFrame))")
            let container = view.textContainer!.size.width, left = view.textContainerOrigin.x, right = view.frame.width - left - container
            check(left >= MarkdownGutter.width + 8 && right >= 18 && container > 150, "panel \(width): text \(container) wide, \(left) and \(right) beside it")
            view.scroll(.zero)
            // Both handles beside a line.
            view.updateGutter(at: NSPoint(x: left + 40, y: view.textContainerOrigin.y + 10))
            check(!view.gutter.isHidden && view.gutter.frame.width == MarkdownGutter.width && view.gutter.frame.minX >= 0 && view.gutter.frame.maxX <= left + 5, "panel \(width): + and grip (\(view.gutter.frame))")
            view.gutter.alphaValue = 1
            if let image = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) {
                pane.cacheDisplay(in: pane.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log + "-panel\(Int(width)).png"))
            }
        }
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            for contents in ["", "短", text] {
                set(view, contents)
                for width in [281, 300.5, 340.33, 401.75, 620] as [CGFloat] {
                    pane.frame = NSRect(x: 0, y: 0, width: width, height: 500)
                    pane.layoutSubtreeIfNeeded()
                    var zoom = 1.0, step = 0.0137
                    for _ in 0..<420 {
                        zoom += step
                        if zoom > 3 { zoom = 3; step = -step } else if zoom < 0.5 { zoom = 0.5; step = -step }
                        editor.setZoom(zoom, at: NSPoint(x: 60, y: scroll.contentView.bounds.minY + 80))
                        view.layoutManager?.ensureLayout(for: view.textContainer!)
                        if abs(view.frame.width - scroll.contentView.bounds.width) > 1 { check(false, "panel \(width) at \(zoom): \(view.frame.width) of \(scroll.contentView.bounds.width)") }
                    }
                    editor.setZoom(1.37, at: nil)
                    for extra in stride(from: 0.0, to: 200, by: 7.3) {
                        pane.frame.size.width = width + extra
                        pane.layoutSubtreeIfNeeded()
                        if abs(view.frame.width - scroll.contentView.bounds.width) > 1 { check(false, "panel \(width)+\(extra): \(view.frame.width) of \(scroll.contentView.bounds.width)") }
                    }
                    editor.setZoom(1, at: nil)
                    check(scroll.magnification == 1, "panel \(width): back at 100%")
                }
            }
        }
    }

    private static func geometry(_ controller: MarkdownWindowController, log: String) {
        let view = controller.editor.textView
        guard let layout = view.layoutManager as? MarkdownLayoutManager else { return }
        var lines: [String] = []
        var failures = 0
        let kinds: [(String, String)] = [("text", ""), ("h1", "# "), ("h2", "## "), ("h3", "### "), ("bullet", "- "), ("number", "1. "), ("task", "- [ ] "), ("done", "- [x] "),
                                         ("quote", "> "), ("quote2", "> > "), ("quote list", "> - "), ("quote head", "> ## "), ("quote bare", ">")]
        let places: [(String, String, String)] = [("only", "", ""), ("first", "", "\n尾"), ("end", "甲\n", ""), ("end after blank", "甲\n\n", ""), ("middle", "甲\n", "\n乙"), ("before newline", "甲\n", "\n"),
                                                  ("after same", "@x\n", ""), ("after code", "```\nx\n```\n", ""), ("after table", "| a |\n| --- |\n| b |\n", "")]
        for (kind, prefix) in kinds {
            for (place, before, after) in places {
                for typed in ["中", "a"] {
                    let lead = before.replacingOccurrences(of: "@", with: prefix)
                    let at = (lead as NSString).length + (prefix as NSString).length
                    set(view, lead + prefix + after, caret: at)
                    let name = "\(kind) / \(place) / \(typed)"
                    var problems: [String] = []
                    guard view.selectedRange().location == at else { failures += 1; lines.append("FAIL \(name): caret at \(view.selectedRange().location) not \(at)"); continue }
                    let caret = caretRect(view)
                    let drawn = layout.decorationFrames(near: at, origin: view.textContainerOrigin)
                    layout.ensureLayout(for: view.textContainer!)
                    let height = bottomOfText(layout)
                    view.insertText(typed, replacementRange: view.selectedRange())
                    let text = baseline(view, at: at)
                    let fallback = view.textStorage!.attribute(.font, at: at, effectiveRange: nil) as! NSFont
                    // The font of the line, not the one Chinese falls back to: they share the baseline.
                    let font = controller.editor.styler.font(fallback.pointSize)
                    let after = caretRect(view)
                    let filled = layout.decorationFrames(near: at, origin: view.textContainerOrigin)
                    let top = text.y - font.ascender, bottom = text.y - font.descender
                    if abs(caret.minX - text.x) > 1.5 { problems.append("caret x \(caret.minX) text x \(text.x)") }
                    if abs(caret.minY - top) > 2.5 || abs(caret.maxY - bottom) > 3.5 { problems.append("caret \(caret.minY)…\(caret.maxY) text \(top)…\(bottom)") }
                    if abs(caret.minY - after.minY) > 1.5 || abs(caret.height - after.height) > 2.5 { problems.append("caret moved \(caret) → \(after)") }
                    layout.ensureLayout(for: view.textContainer!)
                    let newHeight = bottomOfText(layout)
                    if abs(height - newHeight) > 1 { problems.append("text height \(height) → \(newHeight)") }
                    if let mark = drawn?.baseline, abs(mark - text.y) > 1 { problems.append("mark baseline \(mark) text \(text.y)") }
                    if let mark = drawn?.baseline, let now = filled?.baseline, abs(mark - now) > 1 { problems.append("mark moved \(mark) → \(now)") }
                    if let bar = drawn?.bar, let now = filled?.bar, abs(bar.minY - now.minY) > 1 || abs(bar.maxY - now.maxY) > 1 { problems.append("bar moved \(bar) → \(now)") }
                    if let bar = filled?.bar, bar.minY > top + 2 || bar.maxY < bottom - 2 { problems.append("bar \(bar.minY)…\(bar.maxY) text \(top)…\(bottom)") }
                    if !problems.isEmpty { failures += 1; lines.append("FAIL \(name): " + problems.joined(separator: "; ")) }
                }
            }
        }
        lines.append(failures == 0 ? "PASSED" : "FAILED \(failures)")
        try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
    }

    private static func sequences(_ controller: MarkdownWindowController, log: String) {
        let view = controller.editor.textView
        guard let layout = view.layoutManager as? MarkdownLayoutManager, let container = view.textContainer else { return }
        let kinds = ["", "# ", "## ", "### ", "- ", "1. ", "- [ ] ", "> ", "> > ", "> - ", "- a\n  - "]
        let keys: [[Selector]] = [[], [#selector(NSResponder.insertNewline(_:))], [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewline(_:))],
                                  [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewline(_:))],
                                  [#selector(NSResponder.insertLineBreak(_:))], [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.deleteBackward(_:))],
                                  [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:))]]
        var preferences: [MarkdownPreferences] = [MarkdownPreferences()]
        for (size, height, spacing, face) in [(12.0, 1.3, 0.0, MarkdownPreferences.Typeface.system), (22, 2.1, 1.0, .serif), (17, 1.75, 0.6, .mono)] {
            var p = MarkdownPreferences()
            (p.fontSize, p.lineHeight, p.paragraphSpacing, p.typeface) = (size, height, spacing, face)
            preferences.append(p)
        }
        Task { @MainActor in
            var lines: [String] = []
            var checks = 0
            for p in preferences {
                AppDelegate.shared.model.settings.markdown = p
                for kind in kinds {
                    for (index, sequence) in keys.enumerated() {
                        for after in ["", "\n尾"] {
                            set(view, kind + "打" + after, caret: ((kind + "打") as NSString).length)
                            for key in sequence { view.doCommand(by: key) }
                            let at = view.selectedRange().location
                            layout.ensureLayout(for: container)
                            view.updateInsertionPointStateAndRestartTimer(true)
                            try? await Task.sleep(for: .milliseconds(12))
                            let caret = caretRect(view)
                            let indicator = view.subviews.first { $0.className.contains("InsertionIndicator") }?.frame
                            let height = bottomOfText(layout)
                            view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: view.selectedRange())
                            layout.ensureLayout(for: container)
                            let composed = baseline(view, at: at), composedHeight = bottomOfText(layout)
                            view.insertText("你", replacementRange: view.markedRange())
                            layout.ensureLayout(for: container)
                            let text = baseline(view, at: at), textHeight = bottomOfText(layout)
                            let font = (view.textStorage!.attribute(.font, at: at, effectiveRange: nil) as! NSFont).pointSize
                            let top = text.y - ceil(controller.editor.styler.font(font).ascender)
                            var problems: [String] = []
                            if abs(caret.minY - top) > 3 { problems.append("caret \(caret.minY), text from \(top)") }
                            if abs(caret.minX - text.x) > 1.5 { problems.append("caret x \(caret.minX), text x \(text.x)") }
                            if let indicator, view.window?.isKeyWindow == true, abs(indicator.minY - caret.minY) > 2 || abs(indicator.height - caret.height) > 3 || abs(indicator.midX - caret.minX) > 3 { problems.append("blinks at \(indicator), caret \(caret)") }
                            if abs(composed.y - text.y) > 1 { problems.append("composed on \(composed.y), text on \(text.y)") }
                            if abs(height - composedHeight) > 1 || abs(height - textHeight) > 1 { problems.append("text height \(height) → \(composedHeight) → \(textHeight)") }
                            checks += 1
                            if !problems.isEmpty { lines.append("FAIL \(p.fontSize) \(kind.debugDescription) keys \(index) after \(after.debugDescription): " + problems.joined(separator: "; ") + " — \(view.string.debugDescription)") }
                        }
                    }
                }
            }
            lines.append(lines.isEmpty ? "PASSED \(checks)" : "FAILED \(lines.count) of \(checks)")
            try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        }
    }

    private struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private static let samples = ["", "a", "- a\n- b\n  - c\n\n1. x\n2. y", "> q\n> r\n\nt", "a\n\n```py\nx = 1\n```\n\nb", "| a | b |\n| --- | --- |\n| 1 | 2 |", "x\n| a | b |\n| --- | --- |\n| 1 | 2 |\ny",
                                  "# T\n\n- [ ] t\n- [x] d\n\n---\n\n**b** `c` [l](u)", "```\nx\n```\n```\ny\n```", "> - a\n> - b\n>   - c", "- a\n  more\n- b", "| a |\n| - |\n| 1 |\n\n| b |\n| - |\n| 2 |", "\n\n\n"]

    private static func describe(_ view: MarkdownTextView) -> String { "\(view.string.debugDescription) @\(view.selectedRange())" }

    /// What is wrong now (nil: nothing).
    private static func problem(_ controller: MarkdownWindowController) -> String? {
        let view = controller.editor.textView
        guard let storage = view.textStorage, let layout = view.layoutManager as? MarkdownLayoutManager else { return nil }
        let string = view.string as NSString
        let selection = view.selectedRange()
        if NSMaxRange(selection) > string.length { return "selection out of the text" }
        let fresh = MarkdownStructure(string)
        if fresh.codes != view.structure.codes { return "code blocks \(view.structure.codes.map(\.range)) not \(fresh.codes.map(\.range))" }
        if fresh.tables.map(\.range) != view.structure.tables.map(\.range) || fresh.tables.map(\.table) != view.structure.tables.map(\.table) { return "tables \(view.structure.tables) not \(fresh.tables)" }
        if view.blockViews.tables.count != fresh.tables.count { return "\(view.blockViews.tables.count) table views for \(fresh.tables.count)" }
        for (table, entry) in zip(view.blockViews.tables, fresh.tables) {
            if table.table != entry.table, MarkdownTable(rows: table.table.rows.map { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }, alignments: table.table.alignments) != entry.table { return "a table shows \(table.table.rows), its lines say \(entry.table.rows)" }
            if table.superview !== view { return "a table's view is not in the text" }
        }
        if view.window?.firstResponder === view, selection.length == 0, view.structure.table(at: selection.location) == nil {
            let allowed = view.caretLocation(for: selection.location, from: selection.location)
            if allowed != selection.location { return "caret at \(selection.location), where it cannot be (\(allowed))" }
        }
        if selection.length > 0, view.window?.firstResponder === view {
            let allowed = view.selection(for: selection, from: NSRange(location: selection.location, length: 0))
            if allowed != selection { return "selection \(selection) should be \(allowed)" }
        }
        // As it would be styled afresh.
        let copy = NSTextStorage(string: view.string)
        controller.editor.styler.style(copy, range: NSRange(location: 0, length: copy.length), caret: view.window?.firstResponder === view ? selection : nil, structure: view.structure)
        for location in 0..<string.length {
            for key in [NSAttributedString.Key.font, .paragraphStyle, .mdHidden, .mdCodeBlock, .mdQuote, .mdRule, .foregroundColor, .strikethroughStyle, .backgroundColor] {
                let is_ = storage.attribute(key, at: location, effectiveRange: nil) as? NSObject, should = copy.attribute(key, at: location, effectiveRange: nil) as? NSObject
                if is_ != should { return "\(key.rawValue) at \(location): \(String(describing: is_)) not \(String(describing: should))".replacingOccurrences(of: "\n", with: " ") }
            }
            let mine = storage.attribute(.mdDecoration, at: location, effectiveRange: nil) as? MarkdownDecoration, other = copy.attribute(.mdDecoration, at: location, effectiveRange: nil) as? MarkdownDecoration
            if mine?.mark != other?.mark || mine?.textOffset != other?.textOffset || mine?.x != other?.x || mine?.placeholder != other?.placeholder { return "decoration at \(location): \(String(describing: mine?.mark)) \(mine?.placeholder ?? "") not \(String(describing: other?.mark)) \(other?.placeholder ?? "")" }
            let a = storage.attribute(.mdMetrics, at: location, effectiveRange: nil) as? MarkdownMetrics, b = copy.attribute(.mdMetrics, at: location, effectiveRange: nil) as? MarkdownMetrics
            if a?.before != b?.before || a?.after != b?.after || a?.ascent != b?.ascent { return "metrics at \(location)" }
        }
        // Tables where their lines are, and as tall.
        for (index, entry) in view.structure.tables.enumerated() {
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: entry.range.location), effectiveRange: nil).offsetBy(dx: 0, dy: view.textContainerOrigin.y)
            let frame = view.blockViews.tables[index].frame
            if abs(frame.maxY - rect.maxY) > 1.5 { return "table at \(frame.minY)…\(frame.maxY), its line \(rect.minY)…\(rect.maxY)" }
            if rect.height + 6 < frame.height {
 return "table \(frame.height) tall on a line of \(rect.height), told \(view.structure.tableHeights[index]), styled \((storage.attribute(.paragraphStyle, at: entry.range.location, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? -1), container \(view.textContainer!.size.width), responder \(type(of: view.window!.firstResponder!))" }
        }
        return nil
    }

    private static func fuzz(_ controller: MarkdownWindowController, log: String) {
        let view = controller.editor.textView
        guard let window = view.window, let undo = view.undoManager else { return }
        let seeds = max(UserDefaults.standard.integer(forKey: "FolioMarkdownFuzzSeeds"), 40)
        let first = UserDefaults.standard.integer(forKey: "FolioMarkdownFuzzFirst")
        var report: [String] = []
        let grouped = undo.groupsByEvent
        Task { @MainActor in
            for seed in first..<(first + seeds) {
                var random = Random(state: UInt64(seed) &* 7919 &+ 13)
                let sample = samples[seed % samples.count]
                set(view, sample, caret: Int.random(in: 0...(sample as NSString).length, using: &random))
                await Task.yield()
                undo.removeAllActions()
                let start = view.string
                var trace: [String] = []
                var failed: String?
                for _ in 0..<60 {
                    let target = (window.firstResponder as? NSTextView) ?? view
                    func command(_ selector: Selector) { trace.append("\(selector)"); target.doCommand(by: selector) }
                    func type(_ text: String) { trace.append("type \(text.debugDescription)"); target.insertText(text, replacementRange: target.selectedRange()) }
                    switch Int.random(in: 0..<52, using: &random) {
                    case 0..<9: type(["a", "中", " ", "-", "# ", "> ", "`", "*", "1. ", "- ", "|", "[ ] ", "```", "x:", "== "].randomElement(using: &random)!)
                    case 9..<14: command(#selector(NSResponder.insertNewline(_:)))
                    case 14: command(#selector(NSResponder.insertLineBreak(_:)))
                    case 15, 16: command(#selector(NSResponder.insertTab(_:)))
                    case 17: command(#selector(NSResponder.insertBacktab(_:)))
                    case 18..<23: command(#selector(NSResponder.deleteBackward(_:)))
                    case 23: command(#selector(NSResponder.deleteForward(_:)))
                    case 24: command(#selector(NSResponder.moveLeft(_:)))
                    case 25: command(#selector(NSResponder.moveRight(_:)))
                    case 26: command(#selector(NSResponder.moveUp(_:)))
                    case 27: command(#selector(NSResponder.moveDown(_:)))
                    case 28: command(#selector(NSResponder.moveDownAndModifySelection(_:)))
                    case 29: command(#selector(NSResponder.moveUpAndModifySelection(_:)))
                    case 30: command(#selector(NSResponder.moveRightAndModifySelection(_:)))
                    case 31: command(#selector(NSResponder.moveLeftAndModifySelection(_:)))
                    case 32: command(#selector(NSResponder.moveToBeginningOfLine(_:)))
                    case 33: command(#selector(NSResponder.moveToEndOfDocument(_:)))
                    case 34: command(#selector(NSResponder.deleteWordBackward(_:)))
                    case 35: command(#selector(NSResponder.cancelOperation(_:)))
                    case 36: trace.append("selectAll"); target.selectAll(nil)
                    case 37:
                        let style: MarkdownTextView.BlockStyle = [.text, .heading(1), .bullet, .numbered, .task, .quote, .code].randomElement(using: &random)!
                        trace.append("style \(style)"); window.makeFirstResponder(view); view.setBlockStyle(style)
                    case 38: trace.append("table"); window.makeFirstResponder(view); view.insertTable()
                    case 39: trace.append("code"); window.makeFirstResponder(view); view.insertCodeBlock()
                    case 40:
                        let step = Bool.random(using: &random) ? 1 : -1
                        trace.append("move block \(step)"); window.makeFirstResponder(view); view.moveCaretBlock(by: step)
                    case 41: trace.append("delete block"); window.makeFirstResponder(view); view.deleteBlock(view.block(at: view.selectedRange().location))
                    case 42: trace.append("duplicate"); window.makeFirstResponder(view); view.duplicateBlock(view.block(at: view.selectedRange().location))
                    case 43:
                        if let table = view.blockViews.tables.randomElement(using: &random) {
                            let n = Int.random(in: 0..<3, using: &random)
                            trace.append("grow table \(n)")
                            if n == 0 { table.insertRow(at: table.table.rows.count) } else if n == 1 { table.insertColumn(at: 0) } else { table.focus(.start) }
                        }
                    case 44: trace.append("undo"); undo.undo()
                    case 46:
                        trace.append("compose")
                        target.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: target.selectedRange())
                        try? await Task.sleep(for: .milliseconds(3))
                        target.insertText("你", replacementRange: target.markedRange())
                    case 47:
                        let text = samples.randomElement(using: &random)!
                        trace.append("paste \(text.debugDescription)")
                        target.insertText(text, replacementRange: target.selectedRange())
                    case 48: trace.append("wrap"); view.toggleWrap("**")
                    case 49:
                        let length = (view.string as NSString).length
                        let a = Int.random(in: 0...length, using: &random), b = Int.random(in: 0...length, using: &random)
                        trace.append("select \(min(a, b))…\(max(a, b))"); window.makeFirstResponder(view); view.setSelectedRange(NSRange(location: min(a, b), length: abs(a - b)))
                    case 50: trace.append("task"); view.toggleTask(at: view.selectedRange().location)
                    case 51:
                        if let table = view.blockViews.tables.randomElement(using: &random) {
                            trace.append("delete cells")
                            table.focus(.start)
                            if let cell = window.firstResponder as? MarkdownCellView {
                                table.select(from: cell, to: NSPoint(x: CGFloat.random(in: 10...300, using: &random), y: CGFloat.random(in: 10...120, using: &random)))
                                _ = table.deleteSelected()
                            }
                        }
                    default: trace.append("redo"); undo.redo()
                    }
                    try? "\(seed) \(start.debugDescription) \(trace.joined(separator: " · "))".write(toFile: log + ".trace", atomically: true, encoding: .utf8)
                    // What waits for the next turn of the run loop (the caret going on into a table, tables' heights).
                    try? await Task.sleep(for: .milliseconds(4))
                    if let problem = problem(controller) { failed = problem; break }
                }
                if let failed {
                    report.append("FAIL seed \(seed): \(failed)\n     from \(start.debugDescription)\n     \(trace.suffix(12).joined(separator: " · "))\n     \(describe(view))")
                    if report.count > 12 { break }
                    continue
                }
                let end = view.string
                var steps = 0
                while undo.canUndo, steps < 400 { undo.undo(); steps += 1; try? "\(seed) undo \(steps)".write(toFile: log + ".step", atomically: true, encoding: .utf8); try? await Task.sleep(for: .milliseconds(1)) }
                if view.string != start { report.append("FAIL seed \(seed): undone to \(view.string.debugDescription), not \(start.debugDescription)\n     \(trace.joined(separator: " · "))") }
                else if let problem = problem(controller) { report.append("FAIL seed \(seed) after undo: \(problem)") }
                else {
                    while undo.canRedo, steps > 0 { undo.redo(); steps -= 1; try? await Task.sleep(for: .milliseconds(1)) }
                    if view.string != end, !trace.contains("redo") { report.append("FAIL seed \(seed): redone to \(view.string.debugDescription), not \(end.debugDescription)\n     \(trace.joined(separator: " · "))") }
                }
                if report.count > 12 { break }
            }
            _ = grouped
            report.append(report.isEmpty ? "PASSED \(seeds)" : "FAILED \(report.count)")
            try? report.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
        }
    }
}
