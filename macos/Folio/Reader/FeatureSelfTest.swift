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
