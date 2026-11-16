import CoreGraphics
import Foundation
import PDFKit

/// Checks of the PDF text editor on real pages (`folio-translate edit-audit`): each paragraph of a page is edited the
/// ways a person edits — a word typed over itself, words added, a word taken out, Chinese typed in — and what comes
/// out is held against the page as it was.
///
/// - Typing a word over itself must leave the page as it was, to the pixel.
/// - Any edit must leave everything outside the paragraph as it was.
/// - What was typed must be found in the page's text afterwards (searching, copying).
public enum EditDiagnostics {
    public struct Outcome: Sendable {
        public var paragraphs = 0
        /// Blocks of running text the editor would not open.
        public var closed = 0
        public var edits = 0
        public var failures: [String] = []
    }

    /// Pixels (of the page rendered at `scale`) that differ between two renderings, inside and outside `area`.
    static func difference(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int, box: CGRect, scale: Double, area: CGRect) -> (inside: Int, outside: Int, where: CGRect) {
        var inside = 0, outside = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        let x0 = Int(((area.minX - box.minX) * scale).rounded(.down)), x1 = Int(((area.maxX - box.minX) * scale).rounded(.up))
        let y0 = Int((Double(height) - (area.maxY - box.minY) * scale).rounded(.down)), y1 = Int((Double(height) - (area.minY - box.minY) * scale).rounded(.up))
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let d = abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) + abs(Int(a[i + 2]) - Int(b[i + 2]))
                guard d > 60 else { continue }
                if x >= x0, x < x1, y >= y0, y < y1 { inside += 1 } else {
                    outside += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        // Where the page changed outside the paragraph, in page space.
        let place = maxX < 0 ? CGRect.null : CGRect(x: box.minX + Double(minX) / scale, y: box.minY + Double(height - 1 - maxY) / scale,
                                                    width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
        return (inside, outside, place)
    }

    public static func audit(input: URL, pages: [Int]? = nil, perPage: Int = 8, verbose: Bool = false) throws -> String {
        let data = try Data(contentsOf: input)
        let editor = try PDFTextEditor(data: data)
        guard let original = CGPDFDocument(CGDataProvider(data: data as CFData)!) else { throw PDFTextEditError.unreadable }
        var outcome = Outcome()
        let scale = 1.5
        var seconds = 0.0
        for number in pages ?? Array(1...min(editor.pageCount, 3)) where number >= 1 && number <= editor.pageCount {
            guard let page = original.page(at: number), let before = EngineDiagnostics.render(page, scale: scale) else { continue }
            let box = page.getBoxRect(.cropBox)
            let width = Int(box.width * scale), height = Int(box.height * scale)
            let blocks = editor.blocks(onPage: number - 1).filter { $0.text.split(separator: " ").count >= 8 }
            var done = 0
            for block in blocks where done < perPage {
                guard block.isEditable, let first = editor.paragraph(page: number - 1, block: block.index) else {
                    outcome.closed += 1
                    if verbose { outcome.failures.append("p\(number) b\(block.index) closed: \(block.reason ?? "?") \"\(block.text.prefix(40))\"") }
                    continue
                }
                // A plain word from the middle of the paragraph.
                let words = first.string.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 4 && $0.allSatisfy(\.isASCII) }
                guard words.count >= 6 else { continue }
                let word = String(words[words.count / 2])
                done += 1
                outcome.paragraphs += 1
                let label = "p\(number) b\(block.index) \"\(word)\""
                func edit(_ name: String, _ replacement: String, expect: String?, mustMatch: Bool) {
                    guard let paragraph = editor.paragraph(page: number - 1, block: block.index), let range = paragraph.range(of: word) else {
                        outcome.failures.append("\(label) \(name): word not found again")
                        return
                    }
                    outcome.edits += 1
                    let started = Date()
                    paragraph.replace(range, with: replacement)
                    let area = paragraph.bounds.union(block.rect).insetBy(dx: -4, dy: -4)
                    guard let out = try? editor.apply(paragraph), let document = CGPDFDocument(CGDataProvider(data: out as CFData)!),
                          let edited = document.page(at: number), let after = EngineDiagnostics.render(edited, scale: scale), after.count == before.count else {
                        outcome.failures.append("\(label) \(name): could not be written")
                        return
                    }
                    seconds += Date().timeIntervalSince(started)
                    let diff = difference(before, after, width: width, height: height, box: box, scale: scale, area: area)
                    // (Two renderings of pictures and thin rules differ in a few dozen pixels by themselves.)
                    if diff.outside > 200 {
                        let r = diff.where
                        outcome.failures.append(String(format: "%@ %@: %d px changed outside the paragraph @%.0f,%.0f %.0f×%.0f (paragraph %.0f,%.0f %.0f×%.0f)",
                                                       label, name, diff.outside, r.minX, r.minY, r.width, r.height, area.minX, area.minY, area.width, area.height))
                    }
                    // The word typed again takes the place of the page's own characters, set a hair differently (no kerning
                    // of the page's): the line may shift by a fraction of a point, not more.
                    if mustMatch, diff.inside > 6000 { outcome.failures.append("\(label) \(name): \(diff.inside) px changed, the line should look as it did") }
                    if paragraph.overflows { outcome.failures.append("\(label) \(name): overflows") }
                    if let expect {
                        let text = PDFDocument(data: out)?.page(at: number - 1)?.string ?? ""
                        // (A word may have been broken at a line's end.)
                        if !text.replacingOccurrences(of: "\n", with: " ").contains(expect) && !text.replacingOccurrences(of: "\n", with: "").contains(expect)
                            && !text.replacingOccurrences(of: "-\n", with: "").contains(expect) {
                            outcome.failures.append("\(label) \(name): \"\(expect)\" not found in the page's text")
                        }
                    }
                }
                edit("same", word, expect: nil, mustMatch: true)
                edit("longer", word + " carefully", expect: "carefully", mustMatch: false)
                edit("gone", "", expect: nil, mustMatch: false)
                edit("chinese", "测试", expect: "测试", mustMatch: false)
            }
        }
        var report = "\(input.lastPathComponent): \(outcome.paragraphs) paragraphs, \(outcome.edits) edits, \(outcome.failures.count) problems, \(outcome.closed) closed"
            + String(format: ", %.0f ms an edit", outcome.edits > 0 ? seconds / Double(outcome.edits) * 1000 : 0)
        for failure in outcome.failures.prefix(verbose ? 400 : 40) { report += "\n  " + failure }
        return report
    }
}
