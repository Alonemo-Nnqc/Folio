import AppKit
import FolioCore
import PDFKit

/// `-FolioReaderSelfTest <log>` (with `-FolioPreviewOpenReader <title>`): drives the open reader through
/// the same editor, save and position code the mouse uses, then checks the file on disk. No input events.
enum ReaderSelfTest {
    static func run(model: AppModel, fileId: String, log: String) {
        Task { @MainActor in
            var lines: [String] = []
            func note(_ line: String) { lines.append(line) }
            func check(_ ok: Bool, _ what: String) { note((ok ? "PASS " : "FAIL ") + what) }
            try? await Task.sleep(for: .seconds(1.5))
            guard let reader = model.readers.reader(for: fileId), let document = reader.pdfView.document,
                  let editor = reader.pdfView.editor else {
                SimulatedDrop.append("FAIL reader did not open\n", to: log)
                return
            }
            let url = model.fileURL(model.snapshot.files[fileId]!)
            let oldHash = model.snapshot.files[fileId]?.sha256
            check(reader.window?.tabGroup?.selectedWindow === reader.window, "reader tab is selected")
            check(reader.window?.tabGroup?.windows.contains(model.libraryWindow!) == true, "reader shares the library's tab group")
            check(document.page(at: 0) is ReaderPage, "pages are ReaderPage")

            // Markup from the first text line of page 1. (PDFKit adds a Popup next to every note,
            // so counts ignore popups.)
            let page = document.page(at: 0)!
            func count() -> Int { page.annotations.filter { $0.type != "Popup" }.count }
            let line = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine()
                .first { ($0.string ?? "").trimmingCharacters(in: .whitespaces).count > 10 }
            check(line != nil, "page 1 has a text line")
            let before = count()
            // Without real input events nothing closes AppKit's per-event undo groups, so group by hand.
            let undo = reader.window?.undoManager
            undo?.groupsByEvent = false
            func step(_ body: () -> Void) { undo?.beginUndoGrouping(); body(); undo?.endUndoGrouping() }
            step { if let line { editor.addMarkup(.highlight, for: line) } }
            check(count() == before + 1, "highlight added")
            // Separate run-loop turns, like separate clicks: one undo step each.
            try? await Task.sleep(for: .milliseconds(100))
            reader.state.colors[.highlight] = AnnotationColor.blue.rawValue
            step { editor.addInk(points: [NSPoint(x: 100, y: 100), NSPoint(x: 140, y: 130), NSPoint(x: 180, y: 110)], on: page) }
            try? await Task.sleep(for: .milliseconds(100))
            let note = PDFAnnotation(bounds: NSRect(x: 300, y: 300, width: 20, height: 20), forType: .text, withProperties: nil)
            note.contents = "Folio 自测便签"
            step { editor.add(note, to: page) }
            check(count() == before + 3, "ink and note added")
            check(reader.state.annotations.count >= 3, "sidebar lists annotations (\(reader.state.annotations.count))")
            check(page.annotations.contains { $0 is InkAnnotation }, "ink is drawn by the reader (sharp)")
            check(CrispDrawing.isActive, "the reader draws notes, text boxes and ink itself")
            // A stroke run off the page's edge keeps only what is on the page.
            let box = page.bounds(for: .cropBox)
            let runs = AnnotationEditor.runs(of: [NSPoint(x: box.maxX - 20, y: 200), NSPoint(x: box.maxX + 30, y: 200), NSPoint(x: box.maxX + 30, y: 260), NSPoint(x: box.maxX - 20, y: 260)], inside: box)
            check(runs.count == 2 && runs.flatMap { $0 }.allSatisfy { $0.x <= box.maxX + 0.001 }, "ink off the page's edge is cut at the edge (\(runs))")

            // Undo / redo through the window's undo manager (⌘Z / ⇧⌘Z).
            try? await Task.sleep(for: .milliseconds(100))
            reader.window?.undoManager?.undo()
            check(count() == before + 2, "undo removes the last annotation")
            reader.window?.undoManager?.redo()
            check(count() == before + 3, "redo restores it")
            undo?.groupsByEvent = true
            check(reader.window?.isDocumentEdited == true, "window shows unsaved changes")

            // Save and read the file back with a fresh PDFKit document (as Preview would).
            check(reader.save(), "save succeeds")
            check(reader.window?.isDocumentEdited == false, "edited dot cleared after save")
            let reopened = PDFDocument(url: url)
            let types = reopened?.page(at: 0)?.annotations.compactMap(\.type) ?? []
            check(types.contains("Highlight") && types.contains("Ink") && types.contains("Text"),
                  "annotations are in the file: \(types)")
            check(reopened?.page(at: 0)?.annotations.contains { $0.contents == "Folio 自测便签" } == true, "note text saved")
            // Every other reader draws an annotation from its picture: one left empty showed nowhere.
            let empty = reopened?.page(at: 0).map { AppearanceRepair.emptyAppearances(on: $0).map(\.subtype) } ?? ["?"]
            check(empty.isEmpty, "notes, text boxes and ink are saved with their pictures (empty: \(empty))")
            let hidden = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))?
                .filter { $0.contains("folio-saving") } ?? []
            check(hidden.isEmpty, "no temporary files left")

            // Reading position: go to page 2, close, reopen.
            let target = min(2, document.pageCount - 1)
            reader.pdfView.go(to: document.page(at: target)!)
            try? await Task.sleep(for: .seconds(0.5))
            reader.window?.performClose(nil)
            try? await Task.sleep(for: .seconds(1))
            check(model.readers.reader(for: fileId) == nil, "tab closed")
            let saved = try? model.library.readingState(fileId: fileId)
            check(saved?.pageIndex == target, "position saved (page \(saved.map { $0.pageIndex + 1 } ?? 0))")
            model.readers.open(fileId: fileId)
            try? await Task.sleep(for: .seconds(1.5))
            let again = model.readers.reader(for: fileId)
            let current = again?.pdfView.currentPage.flatMap { again?.pdfView.document?.index(for: $0) }
            check(current == target, "position restored (page \((current ?? -1) + 1))")
            check(again?.state.annotations.count == reader.state.annotations.count, "annotations reload with the file")
            let reloaded = again?.pdfView.document?.page(at: 0)?.annotations ?? []
            check(reloaded.contains { $0 is InkAnnotation } && reloaded.contains { $0 is NoteAnnotation }, "reopened ink and notes are the reader's own classes")
            // Ink read from the file is drawn opaque (it was drawn fully transparent: invisible, yet in the list).
            let opacities = reloaded.compactMap { ($0 as? InkAnnotation)?.opacity }
            check(!opacities.isEmpty && opacities.allSatisfy { $0 > 0.99 }, "reopened ink is drawn opaque (\(opacities))")

            // Library follows the file: fingerprint updated, item marked as being read.
            try? await Task.sleep(for: .seconds(1))
            check(model.snapshot.files[fileId]?.sha256 != oldHash, "file fingerprint refreshed")
            check(model.snapshot.items[model.snapshot.files[fileId]!.itemId]?.readStatus != .unread, "item no longer unread")

            // Notes from the reader.
            let itemId = model.snapshot.files[fileId]!.itemId
            model.appendToNote(itemId: itemId, "> quoted text\n> —— 第 1 页")
            check((try? model.library.note(for: itemId))?.contains("quoted text") == true, "添加到笔记 writes the note")
            SimulatedDrop.append(lines.joined(separator: "\n") + "\nDONE\n", to: log)
        }
    }
}
