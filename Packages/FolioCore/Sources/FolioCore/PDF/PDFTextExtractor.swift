import Foundation
import PDFKit

public enum PDFTextExtractor {
    /// All text of the document, or nil when it cannot be opened or has no text layer.
    public static func fullText(of url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// Text of the first `count` pages joined by newlines.
    public static func firstPages(of url: URL, count: Int) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        let pages = (0..<min(count, document.pageCount)).compactMap { document.page(at: $0)?.string }
        let text = pages.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
