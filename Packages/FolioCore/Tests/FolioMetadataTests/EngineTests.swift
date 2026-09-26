import FolioCore
import Foundation
import Testing
@testable import FolioMetadata

@Suite struct EngineTests {
    static let rvsTitle = "RVS-FDSC: A retinal vessel segmentation method with four-directional strip convolution to enhance feature extraction"
    /// The title as it wraps on a real first page.
    static let rvsTitleLines = ["RVS-FDSC: A retinal vessel segmentation method with",
                                "four-directional strip convolution to enhance feature extraction"]

    /// Crossref search response containing only the RVS-FDSC record.
    static func rvsSearchResponse() throws -> Data {
        let work = try JSONSerialization.jsonObject(with: Fixtures.data("crossref_work.json")) as! [String: Any]
        let message = work["message"]!
        return try JSONSerialization.data(withJSONObject: ["status": "ok", "message": ["items": [message]]])
    }

    @Test func verifiedDOIOnFirstPageWins() async throws {
        let pdf = try Fixtures.pdf(lines: Self.rvsTitleLines + ["Linfeng Kong, Yun Wu", "https://doi.org/10.1016/j.bspc.2024.106296"], titleLines: 2)
        let work = try Fixtures.data("crossref_work.json")
        let engine = MetadataEngine.testing { url in
            url.path.hasSuffix("/works/10.1016/j.bspc.2024.106296") ? (work, 200) : (Data(), 404)
        }
        guard case .found(let m) = await engine.resolve(pdfAt: pdf) else { Issue.record("expected a match"); return }
        #expect(m.doi == "10.1016/j.bspc.2024.106296")
    }

    @Test func citedDOIIsRejectedAndTitleSearchFindsThePaper() async throws {
        // Page one cites another paper's DOI; its record must not be accepted.
        let pdf = try Fixtures.pdf(lines: Self.rvsTitleLines + ["Linfeng Kong, Yun Wu", "[1] doi:10.1186/s12880-025-02021-4"], titleLines: 2)
        let cited = try Fixtures.data("crossref_work_abstract.json")
        let search = try Self.rvsSearchResponse()
        let engine = MetadataEngine.testing { url in
            if url.path.hasSuffix("/works/10.1186/s12880-025-02021-4") { return (cited, 200) }
            if url.host() == "api.crossref.org", url.path == "/works" { return (search, 200) }
            return (Data(), 404)
        }
        guard case .found(let m) = await engine.resolve(pdfAt: pdf) else { Issue.record("expected a match"); return }
        #expect(m.title == Self.rvsTitle)
    }

    @Test func offlineReportsNetworkError() async throws {
        let pdf = try Fixtures.pdf(lines: Self.rvsTitleLines + ["Linfeng Kong, Yun Wu", "doi:10.1016/j.bspc.2024.106296"], titleLines: 2)
        let engine = MetadataEngine.testing { _ in throw URLError(.notConnectedToInternet) }
        #expect(await engine.resolve(pdfAt: pdf) == .networkError)
    }

    @Test func noMatchIsNotFound() async throws {
        let pdf = try Fixtures.pdf(lines: ["An Entirely Unknown Paper About Nothing In Particular", "Jane Doe"])
        let engine = MetadataEngine.testing { _ in (Data(), 404) }
        #expect(await engine.resolve(pdfAt: pdf) == .notFound)
    }

    @Test func unreadableFileIsNotFound() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-not-a-pdf-\(UUID().uuidString).pdf")
        try Data("plain text".utf8).write(to: url)
        let engine = MetadataEngine.testing { _ in (Data(), 404) }
        #expect(await engine.resolve(pdfAt: url) == .notFound)
    }

    @Test func identifierResolution() async throws {
        let feed = try Fixtures.data("arxiv_id.xml")
        let engine = MetadataEngine.testing { url in
            url.host() == "export.arxiv.org" ? (feed, 200) : (Data(), 404)
        }
        guard case .found(let m) = await engine.resolve(identifier: "arXiv:2405.02717") else {
            Issue.record("expected a match"); return
        }
        #expect(m.arxivId == "2405.02717")
        #expect(await engine.resolve(identifier: "not an identifier") == .notFound)
    }

    @Test func manualSearchRanksByTitleSimilarity() async throws {
        let search = try Self.rvsSearchResponse()
        let engine = MetadataEngine.testing { url in
            url.host() == "api.crossref.org" && url.path == "/works" ? (search, 200) : (Data(), 404)
        }
        let results = await engine.search(query: "RVS-FDSC retinal vessel segmentation strip convolution")
        #expect(results.first?.doi == "10.1016/j.bspc.2024.106296")
    }
}
