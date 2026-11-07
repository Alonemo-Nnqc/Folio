import AppKit
import CoreText
import Foundation
@testable import FolioCore

enum Fixture {
    static func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "folio-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a one-page PDF whose text layer contains `lines`.
    @discardableResult
    static func pdf(named name: String = "paper.pdf", lines: [String], in dir: URL? = nil) throws -> URL {
        let url = try (dir ?? directory()).appending(path: name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        var y: CGFloat = 740
        for (index, line) in lines.enumerated() {
            let font = CTFontCreateWithName("Helvetica" as CFString, index == 0 ? 20 : 11, nil)
            let attributed = NSAttributedString(string: line, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(ctLine, context)
            y -= index == 0 ? 34 : 16
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static func textFile(named name: String, contents: String, in dir: URL? = nil) throws -> URL {
        let url = try (dir ?? directory()).appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    static func metadata(_ title: String, doi: String? = nil, family: String = "Zhang", year: Int = 2026) -> Metadata {
        var m = Metadata(title: title)
        m.authors = [Author(family: family, given: "Tengya")]
        m.year = year
        m.doi = doi
        m.source = "arXiv"
        return m
    }
}

extension Library {
    /// Imports one file and returns the new standalone item id.
    func importOne(_ url: URL, toGroup groupId: String? = nil) throws -> String {
        guard case .imported(let id, _) = try importFiles([url], toGroup: groupId).first else {
            throw LibraryError.invalidOperation("expected import")
        }
        return id
    }

    /// Imports a PDF and resolves it into a regular item.
    func importItem(_ title: String, doi: String? = nil, toGroup groupId: String? = nil) throws -> String {
        let url = try Fixture.pdf(named: "\(UUID().uuidString).pdf", lines: [title, UUID().uuidString])
        let id = try importOne(url, toGroup: groupId)
        guard case .created = try applyMetadata(Fixture.metadata(title, doi: doi), toStandalone: id, autoRename: true) else {
            throw LibraryError.invalidOperation("expected creation")
        }
        return id
    }

    func rows(_ scope: ViewScope, includeSubgroups: Bool = true, search: String = "") throws -> [String] {
        let s = try snapshot()
        return ViewResolver.rows(ViewQuery(scope: scope, searchText: search, includeSubgroupItems: includeSubgroups,
                                           sort: s.sort(for: scope)), in: s)
    }
}
