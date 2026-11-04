import CoreGraphics
import CoreText
import Foundation
@testable import FolioTranslate

/// A temporary directory removed when the value is deinitialised.
final class TemporaryDirectory: Sendable {
    let url: URL

    init(_ name: String = "FolioTranslateTests") {
        url = FileManager.default.temporaryDirectory
            .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes an executable shell script and returns its URL.
    func script(_ name: String, _ body: String) throws -> URL {
        let file = url.appending(path: name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}

func collect(_ stream: AsyncStream<TranslationEvent>) async -> [TranslationEvent] {
    var events: [TranslationEvent] = []
    for await event in stream { events.append(event) }
    return events
}

/// Builds small test PDFs with Core Graphics: text lines, rules and drawings at known places.
struct TestPDF {
    enum Element {
        case text(String, x: Double, y: Double, size: Double, bold: Bool = false)
        /// A plot: a curve and axes inside `rect`.
        case plot(CGRect)
        /// A horizontal rule.
        case rule(x: Double, y: Double, width: Double)
    }

    static func make(_ pages: [[Element]], size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for page in pages {
            context.beginPDFPage(nil)
            for element in page {
                switch element {
                case .text(let string, let x, let y, let size, let bold):
                    let font = CTFontCreateWithName((bold ? "Times-Bold" : "Times-Roman") as CFString, size, nil)
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                    ]))
                    context.textPosition = CGPoint(x: x, y: y)
                    CTLineDraw(line, context)
                case .plot(let rect):
                    context.setStrokeColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
                    context.setLineWidth(1)
                    context.move(to: CGPoint(x: rect.minX, y: rect.minY))
                    context.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control1: CGPoint(x: rect.midX, y: rect.minY),
                                     control2: CGPoint(x: rect.midX, y: rect.maxY))
                    context.strokePath()
                    context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
                    context.fillEllipse(in: CGRect(x: rect.midX - 3, y: rect.midY - 3, width: 6, height: 6))
                    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
                    context.stroke(rect)
                case .rule(let x, let y, let width):
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fill(CGRect(x: x, y: y, width: width, height: 0.6))
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A paragraph of `lines` lines of body text starting at `top`.
    static func paragraph(_ lines: [String], x: Double = 72, top: Double, size: Double = 10, pitch: Double = 12) -> [Element] {
        lines.enumerated().map { .text($0.element, x: x, y: top - Double($0.offset) * pitch, size: size) }
    }
}
