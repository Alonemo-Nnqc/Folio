import CoreText
import Foundation
import PDFKit
import Testing
@testable import FolioTranslate

/// EDIT-01: a paragraph edited in place keeps the page's fonts and lines; only the lines a change reaches are set again.
@Suite struct ParagraphEditTests {
    static let text = "Extensive work has been carried out towards automatic vessel segmentation or fiber tracing for an extensive review. "
        + "As vasculatures or fibers are curvilinear structures distributed across different orientations and scales, various filtering "
        + "methods have been proposed, including Hessian matrix based filters, symmetry filters, and tensor based filters, to name only the "
        + "most widely used ones. These approaches aim to remove undesired intensity variations in the image, and suppress background "
        + "structures and image noise, thereby easing the subsequent segmentation problem."

    /// A page with one justified paragraph in Times, set by Core Text (its font embedded as a subset).
    static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 420, height: 400)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let style = NSMutableParagraphStyle()
        style.alignment = .justified
        let font = CTFontCreateWithName("Times New Roman" as CFString, 10, nil)
        let string = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style])
        let setter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 50, y: 150, width: 300, height: 200), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    static func paragraph(_ data: Data) throws -> (PDFTextEditor, PDFParagraph) {
        let editor = try PDFTextEditor(data: data)
        let block = try #require(editor.blocks(onPage: 0).max { $0.text.count < $1.text.count })
        let paragraph = try #require(editor.paragraph(page: 0, block: block.index))
        return (editor, paragraph)
    }

    static func pageText(_ data: Data) -> String {
        (PDFDocument(data: data)?.page(at: 0)?.string ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    @Test func untouchedParagraphWritesNothing() throws {
        let data = Self.pdf()
        let (editor, paragraph) = try Self.paragraph(data)
        #expect(paragraph.string.contains("Extensive work"))
        #expect(!paragraph.isModified)
        #expect(try editor.apply(paragraph) == data)
    }

    @Test func deletingAWordKeepsTheEditInItsLines() throws {
        let data = Self.pdf()
        let (editor, paragraph) = try Self.paragraph(data)
        let range = try #require(paragraph.range(of: "automatic "))
        paragraph.replace(range, with: "")
        // The line it was in, and at most the next two: the rest of the paragraph keeps its lines.
        #expect(!paragraph.rewrittenLines.isEmpty && paragraph.rewrittenLines.count <= 3, "\(paragraph.rewrittenLines)")
        #expect(paragraph.rewrittenLines.first == 0)
        let out = try editor.apply(paragraph)
        let text = Self.pageText(out)
        #expect(text.contains("towards vessel segmentation") || text.contains("towards vessel seg"))
        #expect(!text.contains("automatic"))
        #expect(text.contains("subsequent segmentation problem"))
    }

    @Test func deletingACommaChangesOneLine() throws {
        let data = Self.pdf()
        let (editor, paragraph) = try Self.paragraph(data)
        let range = try #require(paragraph.range(of: "image, and"))
        paragraph.replace(range.lowerBound + 5..<range.lowerBound + 6, with: "")
        #expect(paragraph.rewrittenLines.count == 1, "\(paragraph.rewrittenLines)")
        let text = Self.pageText(try editor.apply(paragraph))
        #expect(text.contains("image and suppress") || text.contains("image and"))
    }

    @Test func typingUsesThePagesGlyphsAndOthersStillShow() throws {
        let data = Self.pdf()
        let (editor, paragraph) = try Self.paragraph(data)
        let range = try #require(paragraph.range(of: "image noise"))
        paragraph.replace(range.upperBound..<range.upperBound, with: " (噪声)")
        #expect(paragraph.isModified)
        let preview = paragraph.preview()
        #expect(!preview.cover.isEmpty)
        #expect(preview.page != nil)
        let text = Self.pageText(try editor.apply(paragraph))
        #expect(text.contains("image noise"))
        #expect(text.contains("噪声"))
    }

    @Test func undoingToTheOriginalSnapshotIsUnmodified() throws {
        let data = Self.pdf()
        let (_, paragraph) = try Self.paragraph(data)
        let before = paragraph.snapshot
        let range = try #require(paragraph.range(of: "various"))
        paragraph.replace(range, with: "many")
        #expect(paragraph.isModified)
        paragraph.snapshot = before
        #expect(!paragraph.isModified)
        #expect(paragraph.rewrittenLines.isEmpty)
    }

    @Test func hyphenationPlacesFollowTheDictionary() {
        let points = PDFParagraph.hyphenationPoints("segmentation")
        #expect(!points.isEmpty)
        #expect(points.allSatisfy { $0 >= 2 && $0 <= "segmentation".count - 3 })
    }
}
