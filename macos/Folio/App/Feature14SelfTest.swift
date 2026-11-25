import AppKit
import FolioCore
import PDFKit

/// `-FolioFeature14SelfTest <log>` on a scratch library (`-FolioLibraryPath`): checks 1.5's work through the code the
/// keyboard and mouse use — the live Markdown note editor (typing, input-method composition across an autosave,
/// syntax hidden off the edited line, lists, tasks), Markdown documents (create, edit in the inspector, save, title,
/// open as a tab), and tabs dragged out and put back. No input events; results go to the log,
/// pictures of the editors beside it.
@MainActor
enum Feature14SelfTest {
    static func run(model: AppModel, log: String) {
        Task { @MainActor in
            var lines: [String] = []
            @MainActor func check(_ ok: Bool, _ what: String) { lines.append((ok ? "PASS " : "FAIL ") + what) }
            @MainActor func flush() { SimulatedDrop.append(lines.joined(separator: "\n") + "\n", to: log); lines = [] }
            @MainActor func wait(_ seconds: Double, until: () -> Bool = { false }) async {
                let end = Date().addingTimeInterval(seconds)
                while !until(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
            }
            @MainActor func find<T: NSView>(_ type: T.Type, id: String, in view: NSView?) -> T? {
                guard let view else { return nil }
                if let match = view as? T, match.accessibilityIdentifier() == id { return match }
                for sub in view.subviews { if let found = find(type, id: id, in: sub) { return found } }
                return nil
            }
            @MainActor func picture(_ view: NSView, _ name: String) {
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log + ".\(name).png"))
            }

            await wait(10) { !model.rows.isEmpty }
            guard let library = model.libraryWindow, let itemId = model.rows.first(where: { model.snapshot.items[$0]?.kind == .regular }) else {
                check(false, "library with a paper"); flush(); return
            }
            library.makeKeyAndOrderFront(nil)

            // MARK: Notes
            model.selectedFileIDs = []
            model.selectedItemIDs = [itemId]
            (library.windowController as? LibraryWindowController)?.splitViewController.showInspector()
            model.inspectorTab = .notes
            await wait(3) { find(MarkdownTextView.self, id: "noteEditor", in: library.contentView) != nil }
            guard let note = find(MarkdownTextView.self, id: "noteEditor", in: library.contentView) else {
                check(false, "note editor shown"); flush(); return
            }
            check(true, "note editor shown")
            try? model.library.setNote("", for: itemId)
            NotificationCenter.default.post(name: .folioNoteDidChange, object: itemId)
            await wait(0.3)
            library.makeFirstResponder(note)
            note.setSelectedRange(NSRange(location: (note.string as NSString).length, length: 0))
            for piece in ["# 阅读笔记", "\n", "这是 **重点** 和 `code`", "\n", "- 第一条"] {
                if piece == "\n" { note.insertNewline(nil) } else { note.insertText(piece, replacementRange: note.selectedRange()) }
            }
            note.insertNewline(nil)
            check(note.string.hasSuffix("- 第一条\n- "), "Return continues the list: \(note.string.suffix(12).debugDescription)")
            note.insertText("第二条", replacementRange: note.selectedRange())
            // An input method composing across the autosave: the text must stay as typed.
            note.insertNewline(nil)
            note.setMarkedText("zhong'wen", selectedRange: NSRange(location: 9, length: 0), replacementRange: note.selectedRange())
            await wait(1.4)
            check(note.hasMarkedText(), "composition survives the autosave")
            note.insertText("中文", replacementRange: note.markedRange())
            let typed = note.string
            await wait(1.4)
            check(note.string == typed, "text unchanged after saving")
            check(note.selectedRange().location == (typed as NSString).length, "caret stays at the end")
            let saved = (try? model.library.note(for: itemId)) ?? ""
            check(saved == typed, "note saved: \(saved.debugDescription)")
            check(typed.contains("- 中文"), "list item after composition: \(typed.suffix(10).debugDescription)")
            // Off the edited line, syntax is hidden; on it, shown.
            let storage = note.textStorage!
            let hiddenHeading = storage.attribute(.mdHidden, at: 0, effectiveRange: nil) != nil
            let boldStart = (typed as NSString).range(of: "**").location
            let hiddenBold = storage.attribute(.mdHidden, at: boldStart, effectiveRange: nil) != nil
            let headingFont = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
            check(hiddenHeading && hiddenBold, "markers hidden off the edited line (heading \(hiddenHeading), bold \(hiddenBold) at \(boldStart), active \(note.selectedRange()))")
            let cjkAt = (typed as NSString).range(of: "重点").location
            let cjkFont = storage.attribute(.font, at: cjkAt, effectiveRange: nil) as? NSFont
            let glyphs = (cjkFont.map { font -> Bool in
                var chars = Array("重".utf16); var glyph: CGGlyph = 0
                return CTFontGetGlyphsForCharacters(font, &chars, &glyph, 1)
            }) ?? false
            check(glyphs, "Chinese set in a font that has it (\(cjkFont?.fontName ?? "nil"))")
            check((headingFont?.pointSize ?? 0) > 16, "heading drawn large (\(headingFont?.pointSize ?? 0))")
            note.setSelectedRange(NSRange(location: 3, length: 0))
            check(storage.attribute(.mdHidden, at: 0, effectiveRange: nil) != nil, "a heading's marker stays hidden on the edited line")
            note.setSelectedRange(NSRange(location: boldStart + 3, length: 0))
            check(storage.attribute(.mdHidden, at: boldStart, effectiveRange: nil) == nil, "bold's markers shown while the caret is in it")
            // Tasks: typed, then ticked with the box.
            note.setSelectedRange(NSRange(location: (note.string as NSString).length, length: 0))
            note.insertNewline(nil)
            note.insertNewline(nil)
            note.insertText("- [ ] 读完第三节", replacementRange: note.selectedRange())
            let taskLine = (note.string as NSString).range(of: "- [ ]").location
            note.toggleTask(at: taskLine)
            check(note.string.contains("- [x] 读完第三节"), "task box ticks")
            note.setSelectedRange(NSRange(location: 0, length: 0))
            note.window?.makeFirstResponder(nil)
            await wait(0.3)
            check(storage.attribute(.mdHidden, at: 0, effectiveRange: nil) != nil, "all rendered when the editor loses focus")
            if let scroll = note.enclosingScrollView { picture(scroll, "note") }
            // An input method composing under a heading and inside one: the composition sits where the committed
            // text will (the candidate window follows it).
            note.window?.makeFirstResponder(note)
            note.setSelectedRange(NSRange(location: 0, length: (note.string as NSString).length))
            note.insertText("# 一级标题", replacementRange: note.selectedRange())
            note.insertNewline(nil)
            for (label, newLine) in [("under a heading", true), ("inside a heading", false)] {
                if !newLine {
                    note.setSelectedRange(NSRange(location: 6, length: 0))
                }
                note.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: note.selectedRange())
                var actual = NSRange()
                let composing = note.firstRect(forCharacterRange: note.markedRange(), actualRange: &actual)
                let at = note.markedRange().location
                note.insertText("你", replacementRange: note.markedRange())
                await wait(0.1)
                let committed = note.firstRect(forCharacterRange: NSRange(location: at, length: 1), actualRange: &actual)
                check(abs(composing.minY - committed.minY) < 1 && abs(composing.height - committed.height) < 1,
                      "composition \(label) sits where the text lands (\(Int(composing.minY)),\(Int(composing.height)) → \(Int(committed.minY)),\(Int(committed.height)))")
            }
            flush()

            // MARK: Markdown documents
            let before = Set(model.snapshot.items.keys)
            model.newMarkdownDocument()
            await wait(3) { model.snapshot.items.count > before.count }
            let docId = Set(model.snapshot.items.keys).subtracting(before).first
            let docFile = docId.flatMap { model.defaultFile(of: $0) }
            check(docFile?.isMarkdown == true, "new Markdown document created")
            await wait(3) { find(MarkdownTextView.self, id: "markdownEditor", in: library.contentView) != nil }
            if let editor = find(MarkdownTextView.self, id: "markdownEditor", in: library.contentView), let docFile {
                check(true, "document editor in the inspector")
                library.makeFirstResponder(editor)
                editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
                editor.insertText("# 组会汇报\n\n> 下周三\n\n1. 进展", replacementRange: editor.selectedRange())
                editor.insertNewline(nil)
                check(editor.string.hasSuffix("2. "), "numbered list continues")
                editor.insertText("问题", replacementRange: editor.selectedRange())
                await wait(1.5)
                let onDisk = (try? String(contentsOf: model.fileURL(docFile), encoding: .utf8)) ?? ""
                check(onDisk.contains("2. 问题"), "document saved to its .md file")
                await wait(2) { model.snapshot.items[docId!]?.title == "组会汇报" }
                check(model.snapshot.items[docId!]?.title == "组会汇报", "title follows the heading")
                editor.window?.makeFirstResponder(nil)
                await wait(0.3)
                if let scroll = editor.enclosingScrollView { picture(scroll, "document") }
                // As a tab.
                model.openMarkdown(fileId: docFile.id)
                await wait(2) { model.markdownTabs.controller(for: docFile.id)?.window?.isVisible == true }
                let tab = model.markdownTabs.controller(for: docFile.id)
                check(tab?.window?.tabGroup?.windows.contains(library) == true, "document opens as a tab beside the library")
                check(tab?.editor.text.contains("2. 问题") == true, "tab shows the document")
                // Dragged out, and put back.
                if let tab, let window = tab.window {
                    window.moveTabToNewWindow(nil)
                    await wait(1.5) { tab.isDetachedFromLibrary }
                    FolioWindowController.updateAllReturnButtons()
                    check(tab.isDetachedFromLibrary, "tab moved to a window of its own")
                    check(window.titlebarAccessoryViewControllers.contains { find(NSButton.self, id: "returnToTabs", in: $0.view) != nil },
                          "放回标签页 button shown")
                    tab.moveBackToLibraryTabs(nil)
                    await wait(1.5) { !tab.isDetachedFromLibrary }
                    check(window.tabGroup?.windows.contains(library) == true, "put back into the library's tabs")
                    check(!window.titlebarAccessoryViewControllers.contains { find(NSButton.self, id: "returnToTabs", in: $0.view) != nil },
                          "button gone once back")
                    window.close()
                }
            } else {
                check(false, "document editor in the inspector")
            }
            flush()

            // MARK: Column edges
            if let outline = model.itemListController?.outline, let header = outline.headerView as? ItemHeaderView,
               let clip = outline.enclosingScrollView?.contentView {
                let visible = outline.tableColumns.enumerated().filter { !$0.element.isHidden }
                func span() -> CGFloat {
                    guard let first = visible.first, let last = visible.last else { return 0 }
                    return outline.rect(ofColumn: last.offset).maxX + outline.rect(ofColumn: first.offset).minX
                }
                check(abs(span() - clip.bounds.width) < 2, "columns span the list (\(span()) of \(clip.bounds.width))")
                if visible.count >= 3 {
                    let first = visible[0].element, second = visible[1].element
                    let before = (first.width, second.width)
                    let allBefore = visible.map { Int($0.element.width) }
                    let edge = header.headerRect(ofColumn: visible[0].offset).maxX - 1
                    let y = header.bounds.midY
                    func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
                        let point = header.convert(NSPoint(x: x, y: y), to: nil)
                        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: header.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                    }
                    var afterRelease = 0
                    var released = false
                    let observer = NotificationCenter.default.addObserver(forName: NSTableView.columnDidResizeNotification, object: outline, queue: nil) { _ in
                        MainActor.assumeIsolated { if released { afterRelease += 1 } }
                    }
                    for step in 1...4 { header.window?.postEvent(event(.leftMouseDragged, edge + CGFloat(step) * 10), atStart: false) }
                    header.window?.postEvent(event(.leftMouseUp, edge + 40), atStart: false)
                    header.mouseDown(with: event(.leftMouseDown, edge))
                    released = true
                    await wait(0.3)
                    NotificationCenter.default.removeObserver(observer)
                    _ = second
                    check(abs((first.width - before.0) - 40) < 3,
                          "dragging an edge widens the column, the columns on its right give way (\(allBefore) → \(visible.map { Int($0.element.width) }))")
                    check(abs(span() - clip.bounds.width) < 2, "columns still span the list after the drag")
                    check(afterRelease == 0, "no correction after the mouse is released (\(afterRelease))")
                    check(outline.tableColumns[visible.last!.offset].resizingMask.contains(.userResizingMask) == false, "last column's edge cannot be dragged")
                }
                // Panes sliding beside the list: the columns end exactly at its edges again.
                if let split = (library.windowController as? LibraryWindowController)?.splitViewController,
                   let sidebar = split.splitViewItems.first {
                    let translucency = split.translucency
                    split.translucency = 0.5
                    for _ in 0..<2 {
                        split.setCollapsed(sidebar, !sidebar.isCollapsed)
                        // Mid-slide, what lies behind the sidebar ends where the list begins.
                        var mismatches = 0
                        for _ in 0..<5 {
                            try? await Task.sleep(for: .milliseconds(40))
                            let content = split.splitViewItems[1].viewController.view
                            let edge = content.convert(content.bounds, to: split.splitView).minX
                            if abs(split.sidebarUnderlay.frame.width - max(edge, 0)) > 1 { mismatches += 1 }
                        }
                        check(mismatches == 0, "sidebar underlay follows the list's edge during the slide (\(mismatches) of 5 off)")
                        await wait(0.6)
                        check(abs(span() - clip.bounds.width) < 2, "columns span the list after the sidebar \(sidebar.isCollapsed ? "closed" : "opened") (\(span()) of \(clip.bounds.width))")
                    }
                    split.translucency = translucency
                }
            }
            // Toolbar validation runs after every event: with a paper selected it must stay cheap (it once looked up
            // every app that opens PDFs, 50–200 ms, and made scrolling and pane slides stall).
            if let controller = library.windowController as? LibraryWindowController,
               let paper = model.rows.first(where: { model.snapshot.items[$0]?.kind == .regular }) {
                model.selectedFileIDs = []
                model.selectedItemIDs = [paper]
                await wait(0.3)
                let items = library.toolbar?.items.filter { $0.action != nil } ?? []
                let start = CACurrentMediaTime()
                for _ in 0..<10 { for item in items { _ = controller.validateToolbarItem(item) } }
                let each = (CACurrentMediaTime() - start) * 1000 / 10
                check(each < 5, String(format: "toolbar validation with a paper selected: %.2f ms for %d items", each, items.count))
            }
            // MARK: Several papers at once
            let three = Array(model.rows.filter { model.snapshot.items[$0]?.kind == .regular }.prefix(3))
            if three.count == 3, let controller = library.windowController as? LibraryWindowController {
                model.selectedFileIDs = []
                model.selectedItemIDs = Set(three)
                controller.splitViewController.showInspector()
                await wait(1)
                if let pane = controller.splitViewController.splitViewItems.last?.viewController.view { picture(pane, "multi") }
                let tag = model.snapshot.tags.first { tag in !three.allSatisfy { model.snapshot.itemTags[$0]?.contains(tag.id) ?? false } }
                if let tag {
                    controller.perform(.toggleTag(tag.id), context: ItemMenuContext(scope: model.sidebarSelection, itemIds: three, fileId: nil))
                    await wait(2) { three.allSatisfy { model.snapshot.itemTags[$0]?.contains(tag.id) ?? false } }
                    check(three.allSatisfy { model.snapshot.itemTags[$0]?.contains(tag.id) ?? false }, "a tag added to three papers at once")
                    controller.perform(.toggleTag(tag.id), context: ItemMenuContext(scope: model.sidebarSelection, itemIds: three, fileId: nil))
                    await wait(2) { three.allSatisfy { !(model.snapshot.itemTags[$0]?.contains(tag.id) ?? false) } }
                    check(three.allSatisfy { !(model.snapshot.itemTags[$0]?.contains(tag.id) ?? false) }, "and taken off all three")
                }
            }
            flush()

            // MARK: 多选 from the toolbar
            if let controller = library.windowController as? LibraryWindowController, let outline = model.itemListController?.outline,
               outline.numberOfRows > 3 {
                model.selectedFileIDs = []
                outline.selectRowIndexes([0], byExtendingSelection: false)
                controller.toggleMultiSelect(nil)
                await wait(0.5)
                let button = library.toolbar?.items.first { $0.itemIdentifier == .folioSelect }
                check(model.multiSelectMode && button?.label == "完成", "多选 on from the toolbar (button reads \(button?.label ?? "missing"))")
                // A plain click on another row adds it.
                let rect = outline.rect(ofRow: 2)
                let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                func event(_ type: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: library.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                library.postEvent(event(.leftMouseUp), atStart: false)
                outline.mouseDown(with: event(.leftMouseDown))
                await wait(0.5)
                check(outline.selectedRowIndexes.contains(0) && outline.selectedRowIndexes.contains(2), "a plain click adds a row (\(Array(outline.selectedRowIndexes)))")
                let column = outline.column(withIdentifier: ItemColumn.title.identifier)
                let cell = outline.view(atColumn: column, row: 2, makeIfNecessary: false) as? TitleCell
                check(cell?.icon.image?.accessibilityDescription == "已选中", "selected rows show a filled check circle")
                if let up = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: library.windowNumber,
                                             context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    outline.keyDown(with: up)
                }
                await wait(0.3)
                check(!model.multiSelectMode && button?.label == "多选", "Esc leaves 多选")
            }

            // MARK: The reader's sidebar keeps the page last used
            let withOutline = model.snapshot.files.values.filter { $0.isPDF && $0.translationOf == nil }.sorted { $0.fileName < $1.fileName }.prefix(40)
                .first { (PDFDocument(url: model.fileURL($0))?.outlineRoot?.numberOfChildren ?? 0) > 0 }
            if let sam = withOutline {
                model.open(fileId: sam.id, mode: .reader)
                await wait(6) { model.readers.reader(for: sam.id)?.pdfView.document != nil }
                if let reader = model.readers.reader(for: sam.id) {
                    check(reader.state.sidebarTab == ReaderSidebarTab.remembered,
                          "a paper with a table of contents opens on the page last used (\(reader.state.sidebarTab), outline \(reader.state.outline.count))")
                    reader.window?.close()
                }
            }
            flush()

            // MARK: New papers translated as they arrive
            model.settings.translationService = "google"
            model.settings.autoTranslateImports = true
            let pdf = FileManager.default.temporaryDirectory.appending(path: "Folio 自动翻译自测 \(UUID().uuidString.prefix(6)).pdf")
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            if let context = CGContext(pdf as CFURL, mediaBox: &box, nil) {
                context.beginPDFPage(nil)
                let text = "A Study of Automatic Translation for Newly Added Papers \(UUID().uuidString)"
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 12, nil)]))
                context.textPosition = CGPoint(x: 60, y: 700)
                CTLineDraw(line, context)
                context.endPDFPage()
                context.closePDF()
            }
            let known = Set(model.snapshot.items.keys)
            model.importer.importFiles([pdf], toGroup: nil)
            await wait(10) { model.snapshot.items.count > known.count }
            let added = Set(model.snapshot.items.keys).subtracting(known).first
            await wait(75) { added.map { model.translations.jobs[$0] != nil } ?? false }
            check(added.map { model.translations.jobs[$0] != nil } ?? false, "a new PDF without a translation is queued for translation")
            if let added {
                model.translations.cancel(itemId: added)
                // A paper that is itself a translation is left alone.
                check(TranslationCoordinator.untranslatedPDF(of: added, snapshot: model.snapshot) != nil, "the new paper counts as untranslated")
            }
            if let translated = model.snapshot.files.values.first(where: { $0.translationOf != nil }) {
                check(TranslationCoordinator.untranslatedPDF(of: translated.itemId, snapshot: model.snapshot) == nil, "a paper with a translation is not translated again")
            }
            model.settings.autoTranslateImports = false
            lines.append("done")
            flush()
        }
    }
}
