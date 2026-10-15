import Foundation
import Testing

/// WEB-01: Safari's generated background page declares no charset, so on a Chinese system it decodes the extension's
/// UTF-8 scripts as GBK and they fail to parse. Every script outside the popup (which declares UTF-8) stays ASCII.
@Suite struct BrowserExtensionEncodingTests {
    static let shared = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("BrowserExtension/shared")

    @Test(arguments: ["background.js", "connector.js", "extract.js"])
    func scriptIsPureASCII(_ name: String) throws {
        let data = try Data(contentsOf: Self.shared.appendingPathComponent(name))
        let offenders = data.enumerated().filter { $0.element >= 0x80 }
        let line = offenders.first.map { first in data.prefix(first.offset).filter { $0 == 0x0A }.count + 1 }
        #expect(offenders.isEmpty, "\(name):\(line ?? 0) has non-ASCII bytes; write them as \\u escapes")
    }

    @Test func popupDeclaresUTF8() throws {
        let html = try String(contentsOf: Self.shared.appendingPathComponent("popup.html"), encoding: .utf8)
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(html.contains("src=\"popup.js\" charset=\"utf-8\""))
    }
}
