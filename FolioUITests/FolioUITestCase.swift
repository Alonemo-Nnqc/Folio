import AppKit
import CoreText
import FolioCore
import XCTest

/// Base class: every test gets a fresh temporary library seeded through FolioCore (no network),
/// and the app records "open" requests to a log instead of launching another app.
class FolioUITestCase: XCTestCase {
    var app: XCUIApplication!
    var libraryURL: URL!
    var openLogURL: URL!
    var library: Library!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let base = FileManager.default.temporaryDirectory.appending(path: "folio-ui-\(UUID().uuidString)")
        libraryURL = base.appending(path: "Library")
        openLogURL = base.appending(path: "open.log")
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        library = try Library(root: libraryURL)
        try seed()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        try? FileManager.default.removeItem(at: libraryURL.deletingLastPathComponent())
    }

    /// Override to populate the library before launch.
    func seed() throws {}

    func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-FolioLibraryPath", libraryURL.path, "-FolioOpenLog", openLogURL.path,
                               "-ApplePersistenceIgnoreState", "YES", "-includeSubgroupItems", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    }

    // MARK: Seeding helpers

    @discardableResult
    func addItem(_ title: String, family: String = "Zhang", year: Int = 2025, source: String = "arXiv",
                 doi: String? = nil, extraFiles: Int = 0, group: String? = nil) throws -> String {
        let pdf = try makePDF(named: "\(UUID().uuidString).pdf", lines: [title, UUID().uuidString])
        guard case .imported(let id, _) = try library.importFiles([pdf], toGroup: group).first else {
            throw XCTSkip("seed import failed")
        }
        var metadata = Metadata(title: title)
        metadata.authors = [Author(family: family, given: "Tengya")]
        metadata.year = year
        metadata.source = source
        metadata.doi = doi
        _ = try library.applyMetadata(metadata, toStandalone: id, autoRename: true)
        for index in 0..<extraFiles {
            let extra = try makePDF(named: "supplement-\(index)-\(UUID().uuidString.prefix(4)).pdf", lines: ["Supplement \(index)"])
            _ = try library.addFiles([extra], toItem: id, autoRename: false)
        }
        return id
    }

    func makePDF(named name: String, lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        var y: CGFloat = 740
        for (index, line) in lines.enumerated() {
            let font = CTFontCreateWithName("Helvetica" as CFString, index == 0 ? 18 : 10, nil)
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), context)
            y -= 24
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    // MARK: Query helpers

    var sidebar: XCUIElement { app.outlines["sidebar"] }
    var itemList: XCUIElement { app.outlines["itemList"] }

    /// A sidebar cell by its visible name ("所有文献", a group or tag name).
    func sidebarRow(_ name: String) -> XCUIElement {
        sidebar.cells[name].firstMatch
    }

    /// The outline row containing a cell whose label or value is `text`.
    func itemRow(_ text: String) -> XCUIElement {
        itemList.outlineRows.containing(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    func menuItem(_ title: String) -> XCUIElement {
        app.menuItems[title].firstMatch
    }

    func waitFor(_ element: XCUIElement, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "missing: \(element)", file: file, line: line)
    }

    func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "still present: \(element)",
                       file: file, line: line)
    }

    /// Replaces the text of a focused field. XCUITest cannot synthesise CJK keystrokes, so paste instead.
    func replaceText(in element: XCUIElement, with text: String, submit: Bool = true) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        element.typeKey("a", modifierFlags: .command)
        element.typeKey("v", modifierFlags: .command)
        if submit { element.typeKey(.return, modifierFlags: []) }
    }

    func openedPaths() -> [String] {
        ((try? String(contentsOf: openLogURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
