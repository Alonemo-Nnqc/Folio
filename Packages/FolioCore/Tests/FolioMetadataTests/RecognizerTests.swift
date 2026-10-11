import AppKit
import CoreText
import FolioCore
import Foundation
import Synchronization
import Testing
@testable import FolioMetadata

// MARK: - Payload

@Suite struct RecognizerPayloadTests {
    struct Line {
        var text: String
        var font: String
        var size: CGFloat
        var baseline: CGFloat
    }

    /// PDF with the given lines on page one and one body line on each further page.
    static func pdf(_ lines: [Line], pages: Int = 2, info: [CFString: String] = [:]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-recognizer-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            let pageLines = page == 0 ? lines : [Line(text: "Body text of page \(page + 1)", font: "Helvetica", size: 10, baseline: 700)]
            for line in pageLines {
                let font = CTFontCreateWithName(line.font as CFString, line.size, nil)
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
                context.textPosition = CGPoint(x: 40, y: line.baseline)
                CTLineDraw(ctLine, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    static let sample = [
        Line(text: "Deep Residual Learning for Image Recognition", font: "Helvetica-Bold", size: 18, baseline: 740),
        Line(text: "Kaiming He, Xiangyu Zhang", font: "Helvetica-Oblique", size: 10, baseline: 716),
    ]

    @Test func wordsLinesAndGeometry() throws {
        let url = try Self.pdf(Self.sample, info: [kCGPDFContextTitle: "Deep Residual Learning", kCGPDFContextAuthor: "Kaiming He"])
        let payload = try #require(RecognizerPayload.extract(from: url))
        #expect(payload.totalPages == 2)
        #expect(payload.pages.count == 2)
        #expect(payload.fileName == url.lastPathComponent)
        #expect(payload.metadata["Title"] == "Deep Residual Learning")
        #expect(payload.metadata["Author"] == "Kaiming He")

        let page = payload.pages[0]
        #expect(page.width == 612 && page.height == 792)
        #expect(page.lines.count == 2)
        let title = page.lines[0]
        #expect(title.map(\.text) == ["Deep", "Residual", "Learning", "for", "Image", "Recognition"])
        #expect(title.dropLast().allSatisfy { $0.spaceAfter })
        #expect(title.last?.spaceAfter == false)
        #expect(zip(title, title.dropFirst()).allSatisfy { $0.xMax <= $1.xMin })

        let first = title[0]
        #expect(abs(first.xMin - 40) < 2)
        #expect(first.fontSize == 18)
        #expect(first.bold && !first.italic)
        // Top-left origin: the baseline drawn at y = 740 is 52 pt below the top edge.
        #expect(first.yMin < 52 && first.yMax > 48)
        #expect(abs(first.baseline - 52) < 1.5)
        #expect(first.yMin >= 0 && first.yMin < first.yMax)

        let authors = page.lines[1]
        #expect(authors.map(\.text) == ["Kaiming", "He,", "Xiangyu", "Zhang"])
        #expect(authors.allSatisfy { $0.italic && !$0.bold && $0.fontSize == 10 })
        #expect(authors[0].yMin > first.yMax)
        #expect(authors[0].fontIndex != first.fontIndex)
        #expect(page.fonts.count == 2)
        #expect(page.fonts[first.fontIndex].contains("Bold"))
    }

    @Test func jsonMatchesPDFWorkerLayout() throws {
        let url = try Self.pdf(Self.sample)
        let payload = try #require(RecognizerPayload.extract(from: url))
        let data = try #require(payload.jsonData())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["totalPages"] as? Int == 2)
        #expect(json["fileName"] as? String == url.lastPathComponent)
        #expect(json["metadata"] is [String: String])

        let pages = try #require(json["pages"] as? [[Any]])
        #expect(pages.count == 2)
        let page = pages[0]
        #expect(page.count == 3)
        #expect(page[0] as? Double == 612 && page[1] as? Double == 792)
        // [[[[0, 0, 0, 0, lines]]]]
        let block = try #require(((page[2] as? [Any])?.first as? [Any])?.first as? [Any])
        let paragraph = try #require(block.first as? [Any])
        #expect(paragraph.count == 5)
        #expect(paragraph.prefix(4).allSatisfy { $0 as? Int == 0 })
        let lines = try #require(paragraph[4] as? [[Any]])
        #expect(lines.count == 2)
        // Each line wraps ONE array of words.
        #expect(lines[0].count == 1)
        let words = try #require(lines[0][0] as? [[Any]])
        #expect(words.count == 6)
        let word = words[0]
        #expect(word.count == 14)
        #expect(word[13] as? String == "Deep")
        #expect(word[4] as? Double == 18)
        #expect(word[5] as? Int == 1)                     // spaceAfter
        #expect(word[7] as? Int == 0 && word[8] as? Int == 0 && word[11] as? Int == 0)
        #expect(word[9] as? Int == 1 && word[10] as? Int == 0) // bold, not italic
        #expect(word[12] as? Int == 0)                    // fontIndex
        for value in word.prefix(7).compactMap({ $0 as? Double }) {
            #expect(abs(value * 10_000 - (value * 10_000).rounded()) < 1e-6, "rounded to 4 decimals")
        }
        #expect(words.last?[5] as? Int == 0)
    }

    @Test func atMostFivePages() throws {
        let payload = try #require(RecognizerPayload.extract(from: Self.pdf(Self.sample, pages: 7)))
        #expect(payload.totalPages == 7)
        #expect(payload.pages.count == RecognizerPayload.maxPages)
    }

    @Test func pdfWithoutTextHasNoPayload() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-recognizer-empty-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        #expect(RecognizerPayload.extract(from: url) == nil)
        #expect(RecognizerPayload.extract(from: URL(filePath: "/nonexistent/folio.pdf")) == nil)
    }
}

// MARK: - Response

@Suite struct RecognizerResponseTests {
    @Test func doiAnswer() throws {
        let response = try #require(try ZoteroRecognizerClient.parse(Fixtures.data("recognizer_doi.json")))
        #expect(response.identifiers == [.doi("10.1016/j.bspc.2024.106296")])
        let metadata = try #require(response.metadata)
        #expect(metadata.title.hasPrefix("RVS-FDSC"))
        #expect(metadata.authors == [Author(family: "Kong", given: "Linfeng")])
        #expect(metadata.doi == "10.1016/j.bspc.2024.106296")
        #expect(metadata.url == "https://doi.org/10.1016/j.bspc.2024.106296")
    }

    @Test func arxivAnswer() throws {
        let response = try #require(try ZoteroRecognizerClient.parse(Fixtures.data("recognizer_arxiv.json")))
        #expect(response.identifiers == [.arxiv("2003.06883")])
        #expect(response.language == "en")
        let metadata = try #require(response.metadata)
        #expect(metadata.arxivId == "2003.06883")
        #expect(metadata.authors.count == 6)
        #expect(metadata.authors.last == Author(family: "Lau", given: "Rynson W H"))
        #expect(metadata.abstract?.hasPrefix("Although huge progress") == true)
    }

    @Test func fieldsOnlyAnswerIsDecodedLeniently() throws {
        let response = try #require(try ZoteroRecognizerClient.parse(Fixtures.data("recognizer_fields.json")))
        #expect(response.identifiers.isEmpty)
        #expect(response.issn == "1746-8094")
        let metadata = try #require(response.metadata)
        #expect(metadata.type == .journalArticle)
        #expect(metadata.authors.map(\.family) == ["Kong", "Wu"])
        #expect(metadata.year == 2024 && metadata.date == "2024")
        #expect(metadata.source == "Biomedical Signal Processing and Control")
        #expect(metadata.volume == "95")
        #expect(metadata.issue == nil)
        #expect(metadata.pages == "106296")
        #expect(metadata.publisher == "Elsevier")
        #expect(metadata.url == "https://example.org/rvs")
        #expect(metadata.abstract == "Retinal vessel segmentation is essential for the diagnosis of fundus diseases.")
        #expect(metadata.doi == nil)
    }

    @Test func bookChapterAnswer() throws {
        let response = try #require(try ZoteroRecognizerClient.parse(Fixtures.data("recognizer_chapter.json")))
        #expect(response.identifiers == [.isbn("9780262035613")])
        let metadata = try #require(response.metadata)
        #expect(metadata.type == .bookChapter)
        #expect(metadata.year == 1843)
        #expect(metadata.pages == "666-731")
        #expect(metadata.isbn == "9780262035613")
        #expect(metadata.source == "Scientific Memoirs")
    }

    @Test func emptyAnswersMeanNotRecognised() throws {
        #expect(try ZoteroRecognizerClient.parse(Fixtures.data("recognizer_empty.json")) == nil)
        #expect(try ZoteroRecognizerClient.parse(Data("null".utf8)) == nil)
        #expect(try ZoteroRecognizerClient.parse(Data()) == nil)
        #expect(try ZoteroRecognizerClient.parse(Data("{}".utf8)) == nil)
        #expect(throws: SourceError.malformed) { try ZoteroRecognizerClient.parse(Data("<html>busy</html>".utf8)) }
    }

    @Test func identifierVariants() throws {
        let json = #"{"arxiv":"arXiv:2405.02717v2","doi":"https://doi.org/10.1000/XYZ.1","ISBN":"0-262-03561-X"}"#
        let response = try #require(try ZoteroRecognizerClient.parse(Data(json.utf8)))
        #expect(response.identifiers == [.arxiv("2405.02717"), .doi("10.1000/xyz.1"), .isbn("026203561X")])
    }

    @Test func lookupsSkipDuplicatesAndPlannedIdentifiers() {
        var response = RecognizerResponse()
        response.arxiv = "2405.02717"
        response.doi = "10.48550/arXiv.2405.02717"
        #expect(RecognizerState.lookups(for: response, excluding: []) == [.arxiv("2405.02717")])
        #expect(RecognizerState.lookups(for: response, excluding: [.arxiv("2405.02717")]).isEmpty)
        response.arxiv = nil
        response.doi = "10.1016/j.bspc.2024.106296"
        #expect(RecognizerState.lookups(for: response, excluding: [.doi("10.1016/j.bspc.2024.106296")]).isEmpty)
        #expect(RecognizerState.lookups(for: response, excluding: [.doi("10.1/other")]) == [.doi("10.1016/j.bspc.2024.106296")])
    }
}

// MARK: - Engine

@Suite struct RecognizerEngineTests {
    static let rvsDOI = "10.1016/j.bspc.2024.106296"
    static var rvsLines: [String] { EngineTests.rvsTitleLines + ["Linfeng Kong, Yun Wu"] }

    final class Counter: Sendable {
        private let count = Mutex(0)
        private let body = Mutex<Data?>(nil)
        func record(_ data: Data) { count.withLock { $0 += 1 }; body.withLock { $0 = data } }
        var value: Int { count.withLock { $0 } }
        var lastBody: Data? { body.withLock { $0 } }
    }

    /// The Crossref work fixture with a few fields replaced.
    static func crossrefWork(title: String? = nil, doi: String? = nil, family: String? = nil) throws -> Data {
        var work = try #require(try JSONSerialization.jsonObject(with: Fixtures.data("crossref_work.json")) as? [String: Any])
        var message = try #require(work["message"] as? [String: Any])
        if let title { message["title"] = [title] }
        if let doi { message["DOI"] = doi }
        if let family { message["author"] = [["given": "Andong", "family": family]] }
        work["message"] = message
        return try JSONSerialization.data(withJSONObject: work)
    }

    static func crossrefSearch(doi: String) throws -> Data {
        let work = try #require(try JSONSerialization.jsonObject(with: crossrefWork(doi: doi)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: ["status": "ok", "message": ["items": [work["message"]!]]])
    }

    static func isCrossrefSearch(_ url: URL) -> Bool { url.host() == "api.crossref.org" && url.path == "/works" }

    @Test func recognizerDOIResolvesWhatSearchesMiss() async throws {
        let pdf = try Fixtures.pdf(lines: Self.rvsLines, titleLines: 2)
        let work = try Fixtures.data("crossref_work.json")
        let answer = try Fixtures.data("recognizer_doi.json")
        let http = MockHTTPClient(handler: { url in
            url.path.hasSuffix("/works/\(Self.rvsDOI)") ? (work, 200) : (Data(), 404)
        }, postHandler: { _, _ in (answer, 200) })

        guard case .found(let m) = await MetadataEngine.testing(http).resolve(pdfAt: pdf) else {
            Issue.record("expected a match"); return
        }
        #expect(m.doi == Self.rvsDOI)
        #expect(m.source == "Biomedical Signal Processing and Control")
        // Crossref has no abstract for this work; the recognizer's fills in.
        #expect(m.abstract == "Retinal vessel segmentation is essential for the diagnosis of fundus diseases.")
        // Without the recognizer the searches find nothing.
        #expect(await MetadataEngine.testing(http, useZoteroRecognizer: false).resolve(pdfAt: pdf) == .notFound)
    }

    @Test func verifiedRecognizerFieldsAreUsed() async throws {
        let pdf = try Fixtures.pdf(lines: Self.rvsLines, titleLines: 2)
        let answer = try Fixtures.data("recognizer_fields.json")
        let http = MockHTTPClient(handler: { _ in (Data(), 404) }, postHandler: { _, _ in (answer, 200) })
        guard case .found(let m) = await MetadataEngine.testing(http).resolve(pdfAt: pdf) else {
            Issue.record("expected a match"); return
        }
        #expect(m.title == EngineTests.rvsTitle)
        #expect(m.year == 2024)
        #expect(m.authors.map(\.family) == ["Kong", "Wu"])
        #expect(m.doi == nil)
    }

    @Test func recognizerFieldsForAnotherTitleAreRejected() async throws {
        let pdf = try Fixtures.pdf(lines: ["An Entirely Unknown Paper About Nothing In Particular", "Jane Doe"])
        let answer = try Fixtures.data("recognizer_fields.json")
        let http = MockHTTPClient(handler: { _ in (Data(), 404) }, postHandler: { _, _ in (answer, 200) })
        #expect(await MetadataEngine.testing(http).resolve(pdfAt: pdf) == .notFound)
    }

    @Test func recognizerDOIOfAnotherWorkIsRejected() async throws {
        let pdf = try Fixtures.pdf(lines: Self.rvsLines, titleLines: 2)
        let cited = try Fixtures.data("crossref_work_abstract.json")
        let search = try EngineTests.rvsSearchResponse()
        let http = MockHTTPClient(handler: { url in
            if url.path.hasSuffix("/works/10.1186/s12880-025-02021-4") { return (cited, 200) }
            if Self.isCrossrefSearch(url) { return (search, 200) }
            return (Data(), 404)
        }, postHandler: { _, _ in (Data(#"{"doi":"10.1186/s12880-025-02021-4"}"#.utf8), 200) })
        guard case .found(let m) = await MetadataEngine.testing(http).resolve(pdfAt: pdf) else {
            Issue.record("expected a match"); return
        }
        #expect(m.doi == Self.rvsDOI)
    }

    @Test func recognizerIdentifierOutranksSearchCandidates() async throws {
        let pdf = try Fixtures.pdf(lines: Self.rvsLines, titleLines: 2)
        let work = try Fixtures.data("crossref_work.json")
        let search = try Self.crossrefSearch(doi: "10.9999/rvs.search-copy")
        let answer = try Fixtures.data("recognizer_doi.json")
        let http = MockHTTPClient(handler: { url in
            if url.path.hasSuffix("/works/\(Self.rvsDOI)") { return (work, 200) }
            if Self.isCrossrefSearch(url) {
                try await Task.sleep(for: .milliseconds(150))
                return (search, 200)
            }
            return (Data(), 404)
        }, postHandler: { _, _ in (answer, 200) })

        guard case .found(let m) = await MetadataEngine.testing(http).resolve(pdfAt: pdf) else {
            Issue.record("expected a match"); return
        }
        #expect(m.doi == Self.rvsDOI)
        guard case .found(let old) = await MetadataEngine.testing(http, useZoteroRecognizer: false).resolve(pdfAt: pdf) else {
            Issue.record("expected a match"); return
        }
        #expect(old.doi == "10.9999/rvs.search-copy")
    }

    @Test func pdfsOwnArxivIDOutranksRecognizerDOI() async throws {
        let title = "AFter: Attention-based Fusion Router for RGBT Tracking"
        let pdf = try Fixtures.pdf(lines: [title, "Andong Lu, Wanyu Wang, Chenglong Li", "arXiv:2405.02717v1 [cs.CV] 4 May 2024"])
        let feed = try Fixtures.data("arxiv_id.xml")
        let published = try Self.crossrefWork(title: title, doi: "10.1234/after.2025", family: "Lu")
        let http = MockHTTPClient(handler: { url in
            if url.host() == "export.arxiv.org" {
                try await Task.sleep(for: .milliseconds(300))
                return (feed, 200)
            }
            if url.path.hasSuffix("/works/10.1234/after.2025") { return (published, 200) }
            return (Data(), 404)
        }, postHandler: { _, _ in (Data(#"{"doi":"10.1234/after.2025","title":"AFter"}"#.utf8), 200) })

        guard case .found(let m) = await MetadataEngine.testing(http).resolve(pdfAt: pdf) else {
            Issue.record("expected a match"); return
        }
        #expect(m.arxivId == "2405.02717")
        #expect(m.doi != "10.1234/after.2025")
    }

    @Test func sameWorkSearchRecordStandsInForRecognizerFields() async throws {
        let pdf = try Fixtures.pdf(lines: Self.rvsLines, titleLines: 2)
        let search = try EngineTests.rvsSearchResponse()
        let answer = try Fixtures.data("recognizer_fields.json")
        let http = MockHTTPClient(handler: { url in
            Self.isCrossrefSearch(url) ? (search, 200) : (Data(), 404)
        }, postHandler: { _, _ in (answer, 200) })
        guard case .found(let m) = await MetadataEngine.testing(http).resolve(pdfAt: pdf) else {
            Issue.record("expected a match"); return
        }
        #expect(m.doi == Self.rvsDOI)
        #expect(m.abstract == "Retinal vessel segmentation is essential for the diagnosis of fundus diseases.")
    }

    @Test func slowRecognizerDoesNotHoldBackASearchMatch() async throws {
        let pdf = try Fixtures.pdf(lines: Self.rvsLines, titleLines: 2)
        let search = try EngineTests.rvsSearchResponse()
        let http = MockHTTPClient(handler: { url in
            Self.isCrossrefSearch(url) ? (search, 200) : (Data(), 404)
        }, postHandler: { _, _ in
            try await Task.sleep(for: .seconds(3))
            return (Data(), 404)
        })
        let clock = ContinuousClock()
        var result = ResolveResult.notFound
        let elapsed = await clock.measure { result = await MetadataEngine.testing(http).resolve(pdfAt: pdf) }
        guard case .found(let m) = result else { Issue.record("expected a match"); return }
        #expect(m.doi == Self.rvsDOI)
        #expect(elapsed < .seconds(1.5))
    }

    enum Failure: CaseIterable { case offline, serverError, rejected, malformed, timeout }

    static func failingPost(_ failure: Failure) -> @Sendable (URL, Data) async throws -> (Data, Int) {
        { _, _ in
            switch failure {
            case .offline: throw URLError(.notConnectedToInternet)
            case .serverError: return (Data(), 503)
            case .rejected: return (Data("bad request".utf8), 400)
            case .malformed: return (Data("<html>maintenance</html>".utf8), 200)
            case .timeout:
                try await Task.sleep(for: .seconds(3))
                return (Data(), 200)
            }
        }
    }

    @Test(arguments: Failure.allCases)
    func recognizerFailureLeavesOutcomesUnchanged(_ failure: Failure) async throws {
        // Nothing matches: still a definitive "not found", never a network error.
        let unknown = try Fixtures.pdf(lines: ["An Entirely Unknown Paper About Nothing In Particular", "Jane Doe"])
        let nothing = MockHTTPClient(handler: { _ in (Data(), 404) }, postHandler: Self.failingPost(failure))
        #expect(await MetadataEngine.testing(nothing, recognizerTimeout: .milliseconds(300)).resolve(pdfAt: unknown) == .notFound)

        // A search match is still found.
        let pdf = try Fixtures.pdf(lines: Self.rvsLines, titleLines: 2)
        let search = try EngineTests.rvsSearchResponse()
        let searching = MockHTTPClient(handler: { url in
            Self.isCrossrefSearch(url) ? (search, 200) : (Data(), 404)
        }, postHandler: Self.failingPost(failure))
        guard case .found(let m) = await MetadataEngine.testing(searching, recognizerTimeout: .milliseconds(300)).resolve(pdfAt: pdf) else {
            Issue.record("expected a match"); return
        }
        #expect(m.doi == Self.rvsDOI)

        // Offline stays a network error.
        let offline = MockHTTPClient(handler: { _ in throw URLError(.notConnectedToInternet) }, postHandler: Self.failingPost(failure))
        #expect(await MetadataEngine.testing(offline, recognizerTimeout: .milliseconds(300)).resolve(pdfAt: pdf) == .networkError)
    }

    @Test func disabledRecognizerSendsNothing() async throws {
        let pdf = try Fixtures.pdf(lines: Self.rvsLines, titleLines: 2)
        let posts = Counter()
        let http = MockHTTPClient(handler: { _ in (Data(), 404) }, postHandler: { url, body in
            #expect(url == ZoteroRecognizerClient.endpoint)
            posts.record(body)
            return (Data("{}".utf8), 200)
        })
        _ = await MetadataEngine.testing(http, useZoteroRecognizer: false).resolve(pdfAt: pdf)
        #expect(posts.value == 0)

        _ = await MetadataEngine.testing(http).resolve(pdfAt: pdf)
        #expect(posts.value == 1)
        let body = try #require(posts.lastBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["fileName"] as? String == pdf.lastPathComponent)
        #expect((json["pages"] as? [Any])?.count == 1)
    }
}
