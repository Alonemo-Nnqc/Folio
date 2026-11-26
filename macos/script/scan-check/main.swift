// Recognising and translating scans as a Mac does it: `scan-check <folio-translate> <scan recognised by 1.5> <scan recognised on Windows>`. Compiled and run on each macOS Folio supports.
import AppKit
import CoreText
import PDFKit

let tool = CommandLine.arguments[1]
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scan-check")
try? FileManager.default.removeItem(at: folder)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { failures += 1 } }

func run(_ arguments: [String], limit: TimeInterval = 240) -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try! process.run()
    let killer = DispatchWorkItem { print("STUCK", arguments); process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    killer.cancel()
    return String(decoding: data, as: UTF8.self) + (process.terminationStatus == 0 ? "" : "\nexit \(process.terminationStatus)")
}

let english = ["Scanned documents become searchable", "The quick brown fox jumps over the lazy dog and runs away from the farm.",
               "Tourism brings income to the town, and with it the need to share the burden.", "We describe a model of both, and a plan that keeps them in balance.",
               "Over the years to come, whatever the weather and the season may be.", "The results are compared with those of earlier work on the same towns."]
let chinese = ["基于深度学习的图像识别方法研究", "近年来深度学习方法在图像识别任务中取得了显著的进展。", "本文提出了一种新的网络结构，用于医学图像的分割与分析。",
               "实验结果表明，该方法在多个公开数据集上优于现有方法。", "此外，我们还分析了不同参数对识别结果的影响与意义。"]

func scan(_ pages: [([String], Int)], to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for (lines, turn) in pages {
        let scale = 200.0 / 72, w = Int(612 * scale), h = Int(792 * scale)
        let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        bitmap.setFillColor(gray: 0.96, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bitmap.scaleBy(x: scale, y: scale)
        for (k, line) in lines.enumerated() {
            let cjk = line.unicodeScalars.contains { $0.value > 0x3000 }
            let font = CTFontCreateWithName((cjk ? "PingFang SC" : "Times New Roman") as CFString, k == 0 ? 20 : 14, nil)
            let set = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)]))
            bitmap.textPosition = CGPoint(x: 72, y: 690 - Double(k) * (k == 0 ? 0 : 24) - (k > 0 ? 20 : 0))
            CTLineDraw(set, bitmap)
        }
        var page = turn % 180 == 0 ? box : CGRect(x: 0, y: 0, width: 792, height: 612)
        context.beginPage(mediaBox: &page)
        context.translateBy(x: page.midX, y: page.midY)
        context.rotate(by: Double(turn) * .pi / 180)
        context.draw(bitmap.makeImage()!, in: CGRect(x: -306, y: -396, width: 612, height: 792))
        context.endPage()
    }
    context.closePDF()
}

func squeezed(_ text: String?) -> String { (text ?? "").filter { !$0.isWhitespace }.lowercased() }
func found(_ url: URL, _ words: [(Int, String)]) -> String? {
    guard let document = PDFDocument(url: url) else { return "cannot be opened" }
    let missing = words.filter { !squeezed(document.page(at: $0.0)?.string).contains(squeezed($0.1)) }
    return missing.isEmpty ? nil : "\(missing) not in \(missing.map { (document.page(at: $0.0)?.string ?? "").prefix(160) })"
}

print("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
let source = folder.appendingPathComponent("scan.pdf"), recognised = folder.appendingPathComponent("recognised.pdf")
scan([(english, 0), (chinese, 0), (english, 90)], to: source)
print(run(["ocr", source.path, recognised.path]))
let words = [(0, "quick brown fox"), (1, "深度学习方法"), (2, "quick brown fox")]
check(found(recognised, words) == nil, "recognised: \(found(recognised, words) ?? "")")
func translates(_ url: URL, _ name: String) {
    let out = folder.appendingPathComponent("t-" + name)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let said = run(["fake", url.path, out.path])
    let files = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
    print("  fake:", said.suffix(300), files.map(\.lastPathComponent))
    for (page, word) in [(1, "quick brown fox"), (2, "深度学习方法"), (3, "quick brown fox")] { check(run(["blocks", url.path, "\(page)"]).contains(word), "\(name): page \(page) is translated") }
    check(files.contains { $0.lastPathComponent.hasSuffix("mono.pdf") }, "\(name): the translation is written")
}
translates(recognised, "recognised")

/// What a reader that saves with PDFKit leaves of the text.
func saved(_ name: String, of recognised: URL = recognised, _ change: (PDFDocument) -> Void, data: Bool = false) -> URL {
    let copy = folder.appendingPathComponent("in-\(name).pdf"), out = folder.appendingPathComponent("\(name).pdf")
    try! FileManager.default.copyItem(at: recognised, to: copy)
    let document = PDFDocument(url: copy)!
    change(document)
    if data { try! document.dataRepresentation()!.write(to: out) } else { print("  wrote", document.write(to: out)) }
    return out
}
let highlight: (PDFDocument) -> Void = { document in
    let annotation = PDFAnnotation(bounds: CGRect(x: 72, y: 660, width: 200, height: 20), forType: .highlight, withProperties: nil)
    document.page(at: 0)!.addAnnotation(annotation)
}
for (name, change, data) in [("untouched", { (_: PDFDocument) in }, false), ("untouched-data", { _ in }, true), ("highlighted", highlight, false), ("highlighted-data", highlight, true)] {
    let url = saved(name, change, data: data)
    let problem = found(url, words)
    check(problem == nil, "\(name): \(problem ?? "") size \((try? Data(contentsOf: url).count) ?? 0)")
}
translates(folder.appendingPathComponent("highlighted.pdf"), "highlighted")

// Recognised by Folio 1.5 (one page of English).
let old = URL(fileURLWithPath: CommandLine.arguments[2]), safe = folder.appendingPathComponent("old-safe.pdf")
let oldWords = [(0, "quick brown fox")]
print(run(["safe-to-save", old.path, safe.path]))
check(found(safe, oldWords) == nil, "recognised by 1.5: \(found(safe, oldWords) ?? "")")
let oldSaved = saved("old-highlighted", of: safe, highlight)
check(found(oldSaved, oldWords) == nil, "recognised by 1.5, highlighted: \(found(oldSaved, oldWords) ?? "")")
check(run(["blocks", oldSaved.path, "1"]).contains("quick brown fox"), "recognised by 1.5, highlighted: translated")
// Saved by 1.5 (its text lost before macOS 27): recognised again.
let lost = saved("old-lost", of: old, highlight), again = folder.appendingPathComponent("old-again.pdf")
let facts = run(["ocr", lost.path, "--facts"])
let isLost = found(lost, oldWords) != nil
print("  saved by 1.5:", isLost ? "text lost" : "text kept", facts.prefix(200))
if isLost {
    check(facts.contains("scanned: true"), "text lost by 1.5: offered to be recognised")
    print(run(["ocr", lost.path, again.path]))
    check(found(again, oldWords) == nil, "text lost by 1.5, recognised again: \(found(again, oldWords) ?? "")")
    check(run(["blocks", again.path, "1"]).contains("quick brown fox"), "text lost by 1.5, recognised again: translated")
    check(PDFDocument(url: again)?.page(at: 0)?.annotations.count == 1, "text lost by 1.5, recognised again: the annotation stays")
}
// Recognised by Folio for Windows (the library of a synchronised folder).
let windows = URL(fileURLWithPath: CommandLine.arguments[3])
let windowsWords = [(0, "quick brown fox"), (0, "深度学习方法")]
check(found(windows, windowsWords) == nil, "recognised on Windows: \(found(windows, windowsWords) ?? "")")
check(run(["safe-to-save", windows.path, folder.appendingPathComponent("w.pdf").path]).contains("as it is"), "recognised on Windows: needs nothing")
let windowsSaved = saved("windows-highlighted", of: windows, highlight)
check(found(windowsSaved, windowsWords) == nil, "recognised on Windows, highlighted: \(found(windowsSaved, windowsWords) ?? "")")
check(run(["blocks", windowsSaved.path, "1"]).contains("quick brown fox"), "recognised on Windows, highlighted: translated")
print(failures == 0 ? "PASSED" : "FAILED \(failures)")
exit(failures == 0 ? 0 : 1)
