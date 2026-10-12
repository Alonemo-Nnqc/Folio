import AppKit
import Foundation
import PDFKit

/// A read-only summary of one PDF annotation (INSP-03).
public struct PDFAnnotationInfo: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case highlight, underline, strikeOut, note, freeText

        public var displayName: String {
            switch self {
            case .highlight: "高亮"
            case .underline: "下划线"
            case .strikeOut: "删除线"
            case .note: "注释"
            case .freeText: "文本框"
            }
        }
    }

    public var id: String
    public var kind: Kind
    /// 1-based page number.
    public var page: Int
    public var colorHex: String
    /// Text covered by a markup annotation.
    public var quotedText: String
    /// The user's comment.
    public var comment: String
    public var modified: Date?
}

public enum AnnotationReader {
    public static func annotations(in url: URL) -> [PDFAnnotationInfo] {
        PDFKitSerial.run {
            guard let document = PDFDocument(url: url) else { return [] }
            var result: [PDFAnnotationInfo] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for (offset, annotation) in page.annotations.enumerated() {
                    guard let kind = kind(of: annotation) else { continue }
                    var quoted = ""
                    if kind == .highlight || kind == .underline || kind == .strikeOut {
                        quoted = markedText(annotation, on: page)
                    }
                    let comment = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if quoted.isEmpty && comment.isEmpty { continue }
                    result.append(PDFAnnotationInfo(
                        id: "\(index)-\(offset)", kind: kind, page: index + 1, colorHex: hex(annotation.color),
                        quotedText: quoted, comment: comment, modified: annotation.modificationDate))
                }
            }
            return result
        }
    }

    static func kind(of annotation: PDFAnnotation) -> PDFAnnotationInfo.Kind? {
        // `PDFAnnotation.type` is "Highlight" while `PDFAnnotationSubtype` raw values carry a leading "/".
        let name = (annotation.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch name {
        case "highlight": return .highlight
        case "underline": return .underline
        case "strikeout": return .strikeOut
        case "text": return .note
        case "freetext": return .freeText
        default: return nil
        }
    }

    /// Text under the annotation's quadrilaterals (falls back to its bounds).
    static func markedText(_ annotation: PDFAnnotation, on page: PDFPage) -> String {
        var rects: [CGRect] = []
        if let quads = annotation.quadrilateralPoints, quads.count >= 4 {
            let origin = annotation.bounds.origin
            for start in stride(from: 0, to: quads.count - 3, by: 4) {
                let points = quads[start..<start + 4].map { $0.pointValue }
                let xs = points.map(\.x), ys = points.map(\.y)
                rects.append(CGRect(x: origin.x + xs.min()!, y: origin.y + ys.min()!,
                                    width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
            }
        } else {
            rects = [annotation.bounds]
        }
        // Line by line, so text wrapped across lines keeps a space at each break.
        let pieces = rects.compactMap { page.selection(for: $0.insetBy(dx: 0, dy: 1)) }
            .flatMap { $0.selectionsByLine() }
            .compactMap(\.string)
        return pieces.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#FFD60A" }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}
