import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Vision OCR fallback for scanned first pages (no text layer).
enum PageOCR {
    /// Renders the page at 2x and recognises its text lines, top to bottom.
    /// `fontSize` is approximated by the line's height in page points.
    static func recognizeLines(on page: PDFPage) -> [TextLine] {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0, let image = render(page, bounds: bounds, scale: 2) else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = (request.results ?? []).sorted {
            // Vision uses a bottom-left origin; sort top to bottom, then left to right.
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.005
                ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let height = Double(observation.boundingBox.height * bounds.height)
            return TextLine(text: text, fontSize: (height * 10).rounded() / 10, fontName: "OCR")
        }
    }

    private static func render(_ page: PDFPage, bounds: CGRect, scale: CGFloat) -> CGImage? {
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0, width * height < 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
