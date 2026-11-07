import AppKit
import CoreText
import FolioCore
import Foundation
import Testing
@testable import FolioAgent

/// A PDF whose pages carry the given lines of text (one array per page).
private func makePDF(_ pages: [[String]], name: String = "paper.pdf") throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "folio-agent-pdf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: name)
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    for lines in pages {
        context.beginPDFPage(nil)
        var y: CGFloat = 740
        for line in lines {
            let attributed = NSAttributedString(string: line, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 11, nil)])
            context.textPosition = CGPoint(x: 60, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            y -= 16
        }
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

private func toolbox() throws -> (LibraryToolbox, Library) {
    let library = try Library.temporary()
    return (LibraryToolbox(library: library, configuration: AgentConfiguration(libraryRoot: library.root)), library)
}

private func create(_ library: Library, _ title: String, family: String, year: Int, type: ItemType = .journalArticle) throws -> String {
    var m = Metadata(title: title)
    m.authors = [Author(family: family, given: "A")]
    m.year = year
    m.type = type
    m.source = "Journal of Tests"
    guard case .created(let id) = try library.createItem(m) else { throw ToolError("seed") }
    return id
}

private func ids(_ result: JSONValue, _ key: String = "results") -> [String] {
    (result[key]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
}

@Suite struct ToolFeatureTests {
    @Test func filtersWorkWithAndWithoutAQuery() async throws {
        let (toolbox, library) = try toolbox()
        let a = try create(library, "Retinal Vessel Segmentation with Mamba", family: "Wang", year: 2025)
        let b = try create(library, "Vessel Tracking in Video", family: "Li", year: 2021, type: .conferencePaper)
        let c = try create(library, "Hyperspectral Unmixing", family: "Wang", year: 2023)
        try library.updateItem(c) { $0.readStatus = .read }
        _ = try await toolbox.call("set_tags", arguments: ["items": [.string(a), .string(c)], "add": ["必读"]])

        #expect(ids(try await toolbox.call("search_library", arguments: ["query": "vessel", "year_from": 2024])) == [a])
        #expect(ids(try await toolbox.call("search_library", arguments: ["query": "vessel", "item_type": "conferencePaper"])) == [b])
        #expect(Set(ids(try await toolbox.call("search_library", arguments: ["author": "wang"]))) == [a, c])
        #expect(ids(try await toolbox.call("search_library", arguments: ["tags": ["必读"], "read_status": "read"])) == [c])
        #expect(ids(try await toolbox.call("list_items", arguments: ["year_to": 2022]), "items") == [b], "list_items takes the same filters")
        // An author's family name outranks a word that only appears elsewhere.
        let byAuthor = try await toolbox.call("search_library", arguments: ["query": "li vessel"])
        #expect(ids(byAuthor).first == b)
        await #expect(throws: ToolError.self) { try await toolbox.call("search_library", arguments: [:]) }
        await #expect(throws: ToolError.self) { try await toolbox.call("search_library", arguments: ["tags": ["nope"]]) }
        let paged = try await toolbox.call("search_library", arguments: ["query": "vessel", "limit": 1])
        #expect(paged["next_offset"]?.intValue == 1 && paged["total_matches"]?.intValue == 2)
    }

    @Test func wordStartsCountMoreThanFragments() {
        #expect(LibraryToolbox.containsWord("net", in: "a unet model; network") == true)
        #expect(LibraryToolbox.containsWord("net", in: "a unet model") == false)
        #expect(LibraryToolbox.containsWord("血管", in: "视网膜血管分割") == true)
    }

    @Test func fulltextSearchReturnsPassagesAndReadingFindsPages() async throws {
        let (toolbox, library) = try toolbox()
        let pdf = try makePDF([
            ["A Study of Things", "Introduction to the problem."],
            ["Method", "We minimise the focal loss with a margin of 0.3."],
            ["Results", "The focal loss improves recall; see Table 2."],
        ])
        guard case .imported(let id, _) = try #require(try library.importFiles([pdf]).first) else { Issue.record("import"); return }
        let file = try library.files(ofItem: id)[0]
        try library.setFulltext(fileId: file.id, text: "Introduction. We minimise the focal loss with a margin of 0.3. Results.")

        let found = try await toolbox.call("search_library", arguments: ["query": "focal margin", "include_fulltext": true])
        let hit = try #require(found["results"]?.arrayValue?.first)
        #expect(hit["id"]?.stringValue == id)
        #expect(hit["fulltext_snippet"]?.stringValue?.contains("«focal»") == true)

        let passages = try await toolbox.call("read_fulltext", arguments: ["item": .string(id), "query": "focal loss"])
        let pages = passages["passages"]?.arrayValue?.compactMap { $0["page"]?.intValue } ?? []
        #expect(Set(pages) == [2, 3])
        #expect(passages["passages"]?.arrayValue?.first?["text"]?.stringValue?.lowercased().contains("focal loss") == true)

        let range = try await toolbox.call("read_fulltext", arguments: ["item": .string(id), "start_page": 2, "end_page": 2])
        #expect(range["pages"]?.stringValue == "2-2" && range["text"]?.stringValue?.contains("[Page 2]") == true)
        let inverted = try await toolbox.call("read_fulltext", arguments: ["item": .string(id), "start_page": 3, "end_page": 1])
        #expect(inverted["pages"]?.stringValue == "3-3", "an end before the start reads the start page")
        let none = try await toolbox.call("read_fulltext", arguments: ["item": .string(id), "query": "transformer"])
        #expect(none["hint"] != nil && none["passages"]?.arrayValue?.isEmpty == true)
    }

    @Test func citationsInEveryModeAndStyle() async throws {
        let (toolbox, library) = try toolbox()
        let a = try create(library, "UNet Architecture", family: "Zhang", year: 2026)
        let b = try create(library, "Attention Everywhere", family: "Qi", year: 2025)
        let both = try await toolbox.call("format_citations", arguments: ["items": [.string(a), .string(b)], "style": "APA", "mode": "both"])
        #expect(both["text"]?.stringValue?.contains("Zhang, A. (2026)") == true)
        #expect(both["in_text"]?.arrayValue?.compactMap { $0["citation"]?.stringValue } == ["(Zhang, 2026)", "(Qi, 2025)"])
        #expect(both["in_text_combined"]?.stringValue == "(Qi, 2025; Zhang, 2026)")
        let ieee = try await toolbox.call("format_citations", arguments: ["items": [.string(a)], "style": "ieee", "mode": "in_text"])
        #expect(ieee["text"] == nil && ieee["in_text"]?.arrayValue?.first?["citation"]?.stringValue == "[1]")
        await #expect(throws: ToolError.self) {
            try await toolbox.call("format_citations", arguments: ["items": [.string(a)], "style": "klingon"])
        }
        for style in ["gbt7714", "mla", "chicago", "harvard", "vancouver", "nature", "bibtex"] {
            let out = try await toolbox.call("format_citations", arguments: ["items": [.string(a)], "style": .string(style)])
            #expect(out["text"]?.stringValue?.contains("UNet") == true, "\(style)")
        }
    }

    @Test func filesCanBeAttachedAndAddedFromDisk() async throws {
        let (toolbox, library) = try toolbox()
        let a = try create(library, "Attached Paper", family: "Zhang", year: 2026)
        let pdf = try makePDF([["Attached Paper", "Body."]])
        let attached = try await toolbox.call("attach_file", arguments: ["item": .string(a), "path": .string(pdf.path)])
        #expect(attached["status"]?.stringValue == "attached")
        #expect(attached["item"]?["has_pdf"] == true)
        let again = try await toolbox.call("attach_file", arguments: ["item": .string(a), "path": .string(pdf.path)])
        #expect(again["status"]?.stringValue == "this file is already attached to the item")
        await #expect(throws: ToolError.self) { try await toolbox.call("attach_file", arguments: ["item": .string(a)]) }
        await #expect(throws: ToolError.self) {
            try await toolbox.call("attach_file", arguments: ["item": .string(a), "url": "ftp://example.org/x.pdf"])
        }
        let other = try makePDF([["Another Paper"]], name: "other.pdf")
        let added = try await toolbox.call("add_pdf", arguments: ["path": .string(other.path), "retrieve_metadata": false, "group": "收件箱"])
        #expect(added["status"]?.stringValue == "added without looking up metadata")
        #expect(added["item"]?["groups"]?.stringList == ["收件箱"])
    }

    @Test func recentlyReadItemsComeFirst() async throws {
        let (toolbox, library) = try toolbox()
        let a = try create(library, "Read Long Ago", family: "Zhang", year: 2020)
        let b = try create(library, "Read Yesterday", family: "Li", year: 2021)
        _ = try create(library, "Never Opened", family: "Qi", year: 2022)
        for (id, age) in [(a, 86400.0 * 30), (b, 86400.0)] {
            let pdf = try makePDF([["x"]], name: "\(id).pdf")
            _ = try library.addFiles([pdf], toItem: id, autoRename: false)
            let file = try library.files(ofItem: id)[0]
            try library.saveReadingState(ReadingState(fileId: file.id, pageIndex: 0, pointX: 0, pointY: 0, scale: 1, autoScale: true,
                                                      displayMode: 1, dateModified: Date().addingTimeInterval(-age)))
        }
        let recent = try await toolbox.call("list_items", arguments: ["sort": "last_read"])
        #expect(ids(recent, "items") == [b, a])
        #expect(try await toolbox.call("get_item", arguments: ["item": .string(b)])["last_read"] != nil)
    }
}
