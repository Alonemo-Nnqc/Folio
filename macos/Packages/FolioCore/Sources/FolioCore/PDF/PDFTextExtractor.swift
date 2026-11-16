import Foundation
import PDFKit

public enum PDFTextExtractor {
    /// All text of the document, or nil when it cannot be opened or has no text layer.
    public static func fullText(of url: URL) -> String? {
        PDFKitSerial.run {
            guard let document = PDFDocument(url: url) else { return nil }
            let text = document.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
    }
}
