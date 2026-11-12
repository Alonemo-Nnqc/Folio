import AppKit
import FolioCore
import FolioTranslate
import PDFKit

/// `-FolioFeatureSelfTest <log> -FolioFeatureSample <pdf>` in an empty library (`-FolioLibraryPath`): imports the
/// sample and a scanned copy of its first page, then checks 1.3's features through the code the mouse uses — the
/// eraser (READER-30), 编辑 PDF 文字 with undo (EDIT-01), 扫描件识别 on import (OCR-01) and the shared 划词 cache
/// (SEL-20). No input events; the results go to the log.
@MainActor
enum FeatureSelfTest {
    static func run(model: AppModel, log: String, sample: URL) {
        Task { @MainActor in
            var lines: [String] = []
            func check(_ ok: Bool, _ what: String) { lines.append((ok ? "PASS " : "FAIL ") + what) }
            @MainActor func flush() { SimulatedDrop.append(lines.joined(separator: "\n") + "\n", to: log); lines = [] }
            func wait(_ seconds: Double, until: () -> Bool) async {
                let end = Date().addingTimeInterval(seconds)
                while !until(), Date() < end { try? await Task.sleep(for: .milliseconds(200)) }
            }

            // The eraser's size tiles, drawn into PNGs beside the log (light and dark).
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = EraserSizeMenuView(selected: .medium) { _ in }
                view.appearance = NSAppearance(named: appearance)
                let holder = NSView(frame: view.bounds.insetBy(dx: -8, dy: -8).offsetBy(dx: 8, dy: 8))
                holder.wantsLayer = true
                holder.layer?.backgroundColor = (appearance == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.18, alpha: 1)).cgColor
                holder.appearance = view.appearance
                view.frame.origin = NSPoint(x: 8, y: 8)
                holder.addSubview(view)
                if let rep = holder.bitmapImageRepForCachingDisplay(in: holder.bounds) {
                    holder.cacheDisplay(in: holder.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log + ".eraser-\(name).png"))
                }
            }

            // A scanned copy of page 1: the page as a 200 dpi picture, nothing else.
            let scan = FileManager.default.temporaryDirectory.appending(path: "Folio 扫描件自测.pdf")
            check(makeScan(of: sample, to: scan), "scanned sample written")
            model.importer.importFiles([sample, scan], toGroup: nil)
            await wait(10) { model.snapshot.items.count >= 2 }
            check(model.snapshot.items.count >= 2, "both imported (\(model.snapshot.items.count))")
            guard let textFile = model.snapshot.files.values.first(where: { $0.fileName.hasPrefix(sample.deletingPathExtension().lastPathComponent) }),
                  let scanFile = model.snapshot.files.values.first(where: { $0.fileName.contains("扫描件自测") }) else {
                check(false, "files found"); flush(); return
            }

            // OCR-01: the scan is found and recognised by itself after import.
            await wait(5) { model.ocr.isRecognizing(scanFile.id) }
            check(model.ocr.isRecognizing(scanFile.id) || model.snapshot.files[scanFile.id]?.sha256 != scanFile.sha256, "scan queued for recognition")
            await wait(90) { !model.ocr.isRecognizing(scanFile.id) }
            let recognized = PDFDocument(url: model.fileURL(scanFile))?.page(at: 0)?.string ?? ""
            check(recognized.count > 100, "scan has text now (\(recognized.count) characters): \(recognized.prefix(60).replacingOccurrences(of: "\n", with: " "))")
            check(!FileManager.default.fileExists(atPath: model.library.root.appending(path: ".ocr-backup").path), "backup removed")
            flush()

            // The reader on the text paper.
            model.open(fileId: textFile.id, mode: .reader)
            await wait(5) { model.readers.reader(for: textFile.id)?.pdfView.document != nil }
            guard let reader = model.readers.reader(for: textFile.id), let document = reader.pdfView.document, let page = document.page(at: 0) else {
                check(false, "reader opened"); flush(); return
            }
            try? await Task.sleep(for: .seconds(1))
            let undo = reader.window?.undoManager
            undo?.groupsByEvent = false
            func step(_ body: () -> Void) { undo?.beginUndoGrouping(); body(); undo?.endUndoGrouping() }

            // READER-30: an ink stroke, then the eraser across its middle.
            func inks() -> [PDFAnnotation] { page.annotations.filter { $0.type == "Ink" } }
            step { reader.pdfView.editor?.addInk(points: [NSPoint(x: 100, y: 60), NSPoint(x: 200, y: 60), NSPoint(x: 300, y: 60)], on: page) }
            let strokes = { inks().reduce(0) { $0 + ($1.paths?.count ?? 0) } }
            check(inks().count == 1 && strokes() == 1, "ink drawn")
            reader.state.eraserSize = .medium
            reader.state.tool = .eraser
            try? await Task.sleep(for: .milliseconds(100))
            step {
                reader.pdfView.beginErasing(at: NSPoint(x: 200, y: 90), on: page)
                reader.pdfView.continueErasing(to: NSPoint(x: 200, y: 30), on: page)
                reader.pdfView.endErasing()
            }
            check(strokes() == 2, "eraser cut the stroke in two (\(strokes()) strokes)")
            undo?.undo()
            check(strokes() == 1, "undo brings the whole stroke back")
            undo?.redo()
            check(strokes() == 2, "redo erases again")
            step {
                reader.pdfView.beginErasing(at: NSPoint(x: 90, y: 60), on: page)
                reader.pdfView.continueErasing(to: NSPoint(x: 310, y: 60), on: page)
                reader.pdfView.endErasing()
            }
            check(inks().isEmpty, "erasing along everything removes the annotation")
            reader.state.tool = .select
            undo?.groupsByEvent = true
            check(reader.save(), "saved")
            flush()

            // EDIT-01: edit mode, the first editable block of page 1 replaced, then undone.
            reader.toggleTextEditing(nil)
            check(reader.isEditingPDFText, "edit mode on")
            let data = try? Data(contentsOf: model.fileURL(textFile))
            let editor = data.flatMap { try? PDFTextEditor(data: $0) }
            let block = editor?.blocks(onPage: 0).first { $0.isEditable && $0.text.count > 8 }
            check(block != nil, "an editable block on page 1")
            if let editor, let block {
                let original = block.text
                let replaced = try? editor.replace(block, with: "Folio 编辑自测 EDIT-01")
                check(replaced != nil, "block replaced")
                if let replaced { check(reader.selfTestCommit(replaced), "edit written") }
                let after = reader.pdfView.document?.page(at: 0)?.string ?? ""
                check(after.contains("Folio 编辑自测"), "page shows the new text")
                check(!after.contains(String(original.prefix(20))) || original.count < 20, "old text is gone")
                reader.window?.undoManager?.undo()
                let undone = reader.pdfView.document?.page(at: 0)?.string ?? ""
                check(!undone.contains("Folio 编辑自测"), "undo restores the original")
                reader.window?.undoManager?.redo()
                check((reader.pdfView.document?.page(at: 0)?.string ?? "").contains("Folio 编辑自测"), "redo applies it again")
            }
            reader.toggleTextEditing(nil)
            check(!reader.isEditingPDFText, "edit mode off")

            // The same through the mouse: a click on a block opens it, typing and ⌘↩ write it.
            reader.toggleTextEditing(nil)
            try? await Task.sleep(for: .seconds(3))
            if let window = reader.window, let page0 = reader.pdfView.document?.page(at: 0),
               let blocks = (try? PDFTextEditor(data: Data(contentsOf: model.fileURL(textFile))))?.blocks(onPage: 0),
               let target = blocks.first(where: { $0.isEditable && $0.text.count > 8 && reader.pdfView.convert($0.rect, from: page0).intersects(reader.pdfView.bounds) }) {
                let inView = reader.pdfView.convert(NSPoint(x: target.rect.midX, y: target.rect.midY), from: page0)
                let inWindow = reader.pdfView.convert(inView, to: nil)
                let hit = window.contentView?.superview?.hitTest(inWindow) ?? window.contentView?.hitTest(inWindow)
                lines.append("INFO edit layer: \(reader.textEditState)")
                lines.append("INFO hit view at block: \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                var chain: [String] = []
                var v: NSView? = hit
                while let view = v, chain.count < 8 { chain.append("\(type(of: view))[\(view.subviews.count)]"); v = view.superview }
                lines.append("INFO hit chain: \(chain.joined(separator: " < "))")
                if let doc = reader.pdfView.documentView { lines.append("INFO document view subviews: \(doc.subviews.map { String(describing: type(of: $0)) })") }
                check(hit is PDFTextEditMode, "the edit layer takes the click")
                // The scroll wheel scrolls the pages under the layer.
                let before = reader.pdfView.documentView?.visibleRect.origin.y ?? 0
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0) {
                    cg.location = CGPoint(x: window.frame.minX + inWindow.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - (window.frame.minY + inWindow.y))
                    if let scroll = NSEvent(cgEvent: cg) { hit?.scrollWheel(with: scroll) }
                }
                try? await Task.sleep(for: .milliseconds(300))
                let after = reader.pdfView.documentView?.visibleRect.origin.y ?? 0
                check(abs(after - before) > 20, "the scroll wheel scrolls over a paragraph (\(Int(before)) → \(Int(after)))")
                reader.pdfView.documentView?.scroll(NSPoint(x: reader.pdfView.documentView?.visibleRect.minX ?? 0, y: before))
                try? await Task.sleep(for: .milliseconds(300))
                // The pointer over a paragraph is an I-beam (the layer's, not PDFKit's).
                if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    reader.pdfView.mouseMoved(with: moved)
                }
                check(NSCursor.current == NSCursor.iBeam, "the pointer is an I-beam over a paragraph")
                snapshot(reader, name: "hover", log: log)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(event)
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
                try? await Task.sleep(for: .milliseconds(300))
                snapshot(reader, name: "editing", log: log)
                let editorView = window.firstResponder as? NSTextView
                check(editorView != nil, "a click opens the block for editing (first responder: \(String(describing: window.firstResponder.map { type(of: $0) })))")
                if let editorView {
                    editorView.selectAll(nil)
                    editorView.insertText("Folio 鼠标编辑自测", replacementRange: editorView.selectedRange())
                    window.makeFirstResponder(reader.pdfView)
                    // A click elsewhere finishes it: here the mode is ended, which saves the open edit.
                    reader.toggleTextEditing(nil)
                    try? await Task.sleep(for: .seconds(3))
                    check((reader.pdfView.document?.page(at: 0)?.string ?? "").contains("Folio 鼠标编辑自测"), "the typed text is in the file")
                }
            } else { check(false, "a visible editable block") }
            if reader.isEditingPDFText { reader.toggleTextEditing(nil) }
            flush()

            // SEL-20: the second request for a passage comes from the shared cache.
            let passage = "Folio caches selection translations across readers."
            let start = Date()
            let first = try? await SelectionTranslator.translate(passage, serviceID: "google", fields: [:], secrets: [:], from: "en", to: "zh", fallback: true)
            let firstTime = Date().timeIntervalSince(start)
            let again = Date()
            let second = try? await SelectionTranslator.translate(passage, serviceID: "google", fields: [:], secrets: [:], from: "en", to: "zh", fallback: true)
            let secondTime = Date().timeIntervalSince(again)
            lines.append(String(format: "INFO selection translation: first %.0f ms, again %.1f ms", firstTime * 1000, secondTime * 1000))
            check(first == nil || (second?.text == first?.text && secondTime < 0.05), "repeat comes from the cache")
            flush()
            SimulatedDrop.append("DONE\n", to: log)
        }
    }

    /// The visible part of the pages with the edit layer over them, into `<log>.<name>.png`: the page drawn by PDFKit
    /// (snapshots of PDFView itself come out blank), the layer and its editor by themselves.
    static func snapshot(_ reader: ReaderWindowController, name: String, log: String) {
        guard let documentView = reader.pdfView.documentView, let layer = documentView.subviews.first(where: { $0 is PDFTextEditMode }),
              let page = reader.pdfView.document?.page(at: 0) else { return }
        let visible = documentView.visibleRect
        let scale: CGFloat = 2
        let image = NSImage(size: visible.size)
        image.lockFocusFlipped(documentView.isFlipped)
        NSColor(white: 0.9, alpha: 1).setFill()
        NSRect(origin: .zero, size: visible.size).fill()
        // The page, where it is shown.
        let pageRect = documentView.convert(reader.pdfView.convert(page.bounds(for: .mediaBox), from: page), from: reader.pdfView)
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: pageRect.minX - visible.minX, y: pageRect.minY - visible.minY)
            if documentView.isFlipped { context.translateBy(x: 0, y: pageRect.height); context.scaleBy(x: 1, y: -1) }
            context.scaleBy(x: pageRect.width / page.bounds(for: .mediaBox).width, y: pageRect.height / page.bounds(for: .mediaBox).height)
            NSColor.white.setFill()
            context.fill(page.bounds(for: .mediaBox))
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        image.unlockFocus()
        if let rep = layer.bitmapImageRepForCachingDisplay(in: visible) {
            layer.cacheDisplay(in: visible, to: rep)
            image.lockFocus()
            rep.draw(in: NSRect(origin: .zero, size: visible.size))
            image.unlockFocus()
        }
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(visible.width * scale), pixelsHigh: Int(visible.height * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = visible.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        image.draw(in: NSRect(origin: .zero, size: visible.size))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: log + ".\(name).png"))
    }

    /// Page 1 of `source` drawn into a grey 200 dpi bitmap, written as a PDF of that picture only.
    static func makeScan(of source: URL, to url: URL) -> Bool {
        guard let page = PDFDocument(url: source)?.page(at: 0) else { return false }
        let box = page.bounds(for: .mediaBox)
        let scale = 200.0 / 72
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return false }
        var media = box
        guard let pdf = CGContext(url as CFURL, mediaBox: &media, nil) else { return false }
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: media)
        pdf.endPDFPage()
        pdf.closePDF()
        return true
    }
}
