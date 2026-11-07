import AppKit
import FolioCore
import Foundation
import PDFKit

/// One visual text line of a page with its dominant font.
struct TextLine: Sendable, Hashable {
    var text: String
    /// Point size of the font covering most characters of the line.
    var fontSize: Double
    /// PostScript name of that font without the subset prefix ("ABCDEF+").
    var fontName: String
}

/// Everything the engine needs from a PDF, extracted once up front.
struct PDFFacts: Sendable, Equatable {
    var fileName: String
    var embeddedTitle: String?
    var embeddedAuthor: String?
    /// Info dictionary Subject/Keywords plus the raw XMP packet; used for identifier extraction.
    var metadataText: String = ""
    var firstPageText: String = ""
    var secondPageText: String = ""
    var firstPageLines: [TextLine] = []
    /// True when the first page had no text layer and was recognised with Vision.
    var usedOCR = false

    init(fileName: String, embeddedTitle: String? = nil, embeddedAuthor: String? = nil,
         metadataText: String = "", firstPageText: String = "", secondPageText: String = "",
         firstPageLines: [TextLine] = [], usedOCR: Bool = false) {
        self.fileName = fileName
        self.embeddedTitle = embeddedTitle
        self.embeddedAuthor = embeddedAuthor
        self.metadataText = metadataText
        self.firstPageText = firstPageText
        self.secondPageText = secondPageText
        self.firstPageLines = firstPageLines
        self.usedOCR = usedOCR
    }

    /// Reads the facts from a PDF on disk. Returns nil when the file is not a readable PDF.
    static func extract(from url: URL) -> PDFFacts? {
        PDFKitSerial.run {
            guard let document = PDFDocument(url: url) else { return nil }
            if document.isLocked, !document.unlock(withPassword: "") { return nil }

            var facts = PDFFacts(fileName: url.lastPathComponent)
            let attributes = document.documentAttributes ?? [:]
            facts.embeddedTitle = stringAttribute(attributes[PDFDocumentAttribute.titleAttribute])
            facts.embeddedAuthor = stringAttribute(attributes[PDFDocumentAttribute.authorAttribute])
            facts.metadataText = [
                stringAttribute(attributes[PDFDocumentAttribute.subjectAttribute]),
                stringAttribute(attributes[PDFDocumentAttribute.keywordsAttribute]),
                xmpPacket(of: document),
            ].compactMap { $0 }.joined(separator: "\n")

            if let first = document.page(at: 0) {
                facts.firstPageLines = lines(of: first)
                facts.firstPageText = facts.firstPageLines.map(\.text).joined(separator: "\n")
                if facts.firstPageText.filter(\.isLetter).count < 20 {
                    let recognised = PageOCR.recognizeLines(on: first)
                    if !recognised.isEmpty {
                        facts.firstPageLines = recognised
                        facts.firstPageText = recognised.map(\.text).joined(separator: "\n")
                        facts.usedOCR = true
                    }
                }
            }
            if document.pageCount > 1, let second = document.page(at: 1) {
                facts.secondPageText = second.string ?? ""
            }
            return facts
        }
    }

    // MARK: - Helpers

    private static func stringAttribute(_ value: Any?) -> String? {
        let text: String?
        switch value {
        case let string as String: text = string
        case let strings as [String]: text = strings.joined(separator: " ")
        case let array as [Any]: text = array.map { "\($0)" }.joined(separator: " ")
        default: text = nil
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The document-level XMP packet (catalog `/Metadata` stream), decoded.
    private static func xmpPacket(of document: PDFDocument) -> String? {
        guard let catalog = document.documentRef?.catalog else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else { return nil }
        return String(data: data.prefix(256 * 1024), encoding: .utf8)
    }

    /// Splits the page's attributed text into lines and records each line's dominant font.
    static func lines(of page: PDFPage) -> [TextLine] {
        guard let attributed = page.attributedString, attributed.length > 0 else { return [] }
        let string = attributed.string as NSString
        var result: [TextLine] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { substring, range, _, _ in
            guard let substring else { return }
            let text = substring.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            var weights: [FontKey: Int] = [:]
            attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
                guard let font = value as? NSFont else { return }
                let key = FontKey(size: (Double(font.pointSize) * 10).rounded() / 10,
                                  name: baseFontName(font.fontName))
                weights[key, default: 0] += subrange.length
            }
            let dominant = weights.max { $0.value < $1.value || ($0.value == $1.value && $0.key.size < $1.key.size) }?.key
            result.append(TextLine(text: text, fontSize: dominant?.size ?? 0, fontName: dominant?.name ?? ""))
        }
        return result
    }

    private struct FontKey: Hashable {
        var size: Double
        var name: String
    }

    static func baseFontName(_ name: String) -> String {
        // Subset fonts are named "ABCDEF+RealName".
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
            return String(name[name.index(after: plus)...])
        }
        return name
    }
}
