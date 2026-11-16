import CoreGraphics
import Foundation
import Testing
@testable import FolioTranslate

/// Text coloured in the page's own colour spaces reads as the colour it shows: journals often set black text as full ink
/// of a Separation "Black", which reading `1 scn` as gray turned white, and its translation invisible.
struct ColorSpaceTests {
    /// A one-page PDF with the colour spaces /Sep (Separation Black, Type 2 function), /Calc (Separation, PostScript
    /// function to CMYK), /Idx (Indexed RGB: 0 white, 1 black, 2 red), /None (Separation with no function to follow)
    /// and /ICC (ICC-based gray).
    static func pdf(content: String) -> Data {
        let calc = "{ dup 0 mul exch dup 0 mul exch dup 0 mul exch 1 mul }"
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> "
                       + "/ColorSpace << /Sep [/Separation /Black /DeviceGray << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>] "
                       + "/Calc [/Separation /Black /DeviceCMYK 6 0 R] /Idx [/Indexed /DeviceRGB 2 <FFFFFF000000FF0000>] "
                       + "/None [/Separation /Spot /DeviceGray 99 0 R] /ICC [/ICCBased 7 0 R] >> >> >>")
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 /Widths [\(Array(repeating: "500", count: 95).joined(separator: " "))] >>")
        objects.append("<< /FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1 0 1] /Length \(calc.utf8.count) >>\nstream\n\(calc)\nendstream")
        objects.append("<< /N 1 /Length 0 >>\nstream\n\nendstream")
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    static func colors(_ content: String) -> [RGBColor] {
        let document = CGPDFDocument(CGDataProvider(data: pdf(content: content) as CFData)!)!
        let interpreter = ContentInterpreter()
        interpreter.run(page: document.page(at: 1)!)
        return interpreter.glyphs.map(\.color)
    }

    @Test func fullInkOfASeparationIsBlackNotWhite() {
        let c = Self.colors("BT /F1 10 Tf 50 100 Td /Sep cs 1 scn (A) Tj 0 scn (B) Tj /Sep cs (C) Tj ET")
        #expect(c[0] == .black)
        #expect(c[1] == RGBColor(r: 1, g: 1, b: 1))
        // Choosing the space starts at full ink.
        #expect(c[2] == .black)
    }

    @Test func postScriptTintFunctionsAreFollowed() {
        let c = Self.colors("BT /F1 10 Tf 50 100 Td /Calc cs 1 sc (A) Tj 0.5 sc (B) Tj ET")
        #expect(c[0] == .black)
        #expect(abs(c[1].r - 0.5) < 0.001 && abs(c[1].g - 0.5) < 0.001)
    }

    @Test func indexedAndICCColoursReadTheirTables() {
        let c = Self.colors("BT /F1 10 Tf 50 100 Td /Idx cs 1 scn (A) Tj 2 scn (B) Tj /ICC cs 0 scn (C) Tj 0 0 1 rg (D) Tj ET")
        #expect(c[0] == .black)
        #expect(c[1] == RGBColor(r: 1, g: 0, b: 0))
        #expect(c[2] == .black)
        #expect(c[3] == RGBColor(r: 0, g: 0, b: 1))
    }

    @Test func aSpotColourWithoutItsFunctionIsStillInk() {
        let c = Self.colors("BT /F1 10 Tf 50 100 Td /None cs 1 scn (A) Tj ET")
        #expect(c[0] == .black)
    }

    @Test func paleTextOnBarePaperIsRedrawnInBlack() {
        let document = CGPDFDocument(CGDataProvider(data: Self.pdf(content: "BT /F1 10 Tf 50 100 Td 1 g (A) Tj ET 0 0 1 rg 40 180 100 30 re f BT /F1 10 Tf 50 190 Td 1 g (B) Tj ET") as CFData)!)!
        let interpreter = ContentInterpreter()
        interpreter.run(page: document.page(at: 1)!)
        // White on the paper: shown in black. White on the blue box: as it is.
        #expect(interpreter.visibleColor(of: interpreter.glyphs[0]) == .black)
        #expect(interpreter.visibleColor(of: interpreter.glyphs[1]) == RGBColor(r: 1, g: 1, b: 1))
    }
}
