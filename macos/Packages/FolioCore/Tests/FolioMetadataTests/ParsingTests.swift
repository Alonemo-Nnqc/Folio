import FolioCore
import Foundation
import Testing
@testable import FolioMetadata

@Suite struct ParsingTests {
    @Test func crossrefWork() throws {
        let m = try #require(try CrossrefClient.parseWork(Fixtures.data("crossref_work.json")))
        #expect(m.doi == "10.1016/j.bspc.2024.106296")
        #expect(m.title.hasPrefix("RVS-FDSC: A retinal vessel segmentation method"))
        #expect(m.source == "Biomedical Signal Processing and Control")
        #expect(m.volume == "95")
        #expect(m.type == .journalArticle)
        #expect(m.authors.first?.family == "Kong")
        #expect(m.year != nil)
    }

    @Test func crossrefWorkWithoutAbstract() throws {
        let m = try #require(try CrossrefClient.parseWork(Fixtures.data("crossref_work_abstract.json")))
        #expect(m.title == "Full-scale representation guided network for retinal vessel segmentation")
        #expect(!(m.abstract ?? "").contains("<jats:"))
    }

    @Test func crossrefSearchMapsProceedings() throws {
        let results = try CrossrefClient.parseSearch(Fixtures.data("crossref_search.json"))
        #expect(!results.isEmpty)
        #expect(results.first?.type == .conferencePaper)
    }

    @Test func arxivEntry() throws {
        let m = try #require(try ArxivClient.parse(Fixtures.data("arxiv_id.xml")).first)
        #expect(m.title == "AFter: Attention-based Fusion Router for RGBT Tracking")
        #expect(m.type == .preprint)
        #expect(m.source == "arXiv")
        #expect(m.arxivId == "2405.02717")
        #expect(m.doi == "10.48550/arxiv.2405.02717")
        #expect(!m.authors.isEmpty)
    }

    @Test func arxivErrorFeedHasNoEntries() throws {
        #expect(try ArxivClient.parse(Fixtures.data("arxiv_error.xml")).isEmpty)
    }

    @Test func dataciteCSL() throws {
        let m = try #require(try DOIContentNegotiationClient.parse(Fixtures.data("csl_datacite.json")))
        #expect(m.title == "AFter: Attention-based Fusion Router for RGBT Tracking")
        #expect(m.doi == "10.48550/arxiv.2405.02717")
        #expect(m.authors.first?.family == "Lu")
    }

    @Test func openAlexRebuildsAbstractAndStripsDOIPrefix() throws {
        let results = try OpenAlexClient.parse(Fixtures.data("openalex_search.json"))
        #expect(results.count == 2)
        #expect(results.first?.doi == "10.1109/tip.2025.3586467")
        #expect(results.contains { !($0.abstract ?? "").isEmpty })
    }

    @Test func openLibraryEdition() throws {
        let m = try #require(try OpenLibraryClient.parseEdition(Fixtures.data("openlibrary_isbn.json"), isbn: "9780262035613"))
        #expect(m.title == "Deep Learning")
        #expect(m.type == .book)
        #expect(m.publisher == "MIT Press")
        #expect(m.year == 2017)
    }
}

@Suite struct IdentifierTests {
    @Test func parsesCommonForms() {
        #expect(Identifier.parse("https://doi.org/10.1038/NATURE14539") == .doi("10.1038/nature14539"))
        #expect(Identifier.parse("doi:10.1016/j.bspc.2024.106296.") == .doi("10.1016/j.bspc.2024.106296"))
        #expect(Identifier.parse("arXiv:2604.27326v2") == .arxiv("2604.27326"))
        #expect(Identifier.parse("https://arxiv.org/abs/2405.02717") == .arxiv("2405.02717"))
        #expect(Identifier.parse("2405.02717") == .arxiv("2405.02717"))
        #expect(Identifier.parse("hep-th/9901001") == .arxiv("hep-th/9901001"))
        #expect(Identifier.parse("ISBN 978-0-262-03561-3") == .isbn("9780262035613"))
        #expect(Identifier.parse("Attention is all you need") == nil)
    }

    @Test func rejectsInvalidISBNChecksum() {
        #expect(Identifier.parse("978-0-262-03561-4") == nil)
    }

    @Test func extractsArxivStampAsSelfDescribing() throws {
        let facts = PDFFacts(fileName: "paper.pdf", firstPageText: "arXiv:2501.08458v2 [eess.IV] 15 Jan 2025\nRWKV-UNet")
        let found = IdentifierExtractor.extract(from: facts)
        let arxiv = try #require(found.first { $0.isArxiv })
        #expect(arxiv.identifier == .arxiv("2501.08458"))
        #expect(arxiv.isSelfDescribing)
    }

    @Test func mapsArxivDOIToID() {
        #expect(IdentifierExtractor.arxivID(fromDOI: "10.48550/arxiv.2405.02717") == "2405.02717")
        #expect(IdentifierExtractor.arxivID(fromDOI: "10.1109/tip.2025.3586467") == nil)
    }
}

@Suite struct TitleAndScoringTests {
    @Test func guessesLargestLineAsTitle() throws {
        let url = try Fixtures.pdf(lines: ["Night-Time Scene Parsing With a Large Real Dataset",
                                           "Xin Tan, Ke Xu, Ying Cao", "Abstract—Although huge progress has been made"])
        let facts = try #require(PDFFacts.extract(from: url))
        #expect(TitleGuesser.guesses(from: facts).first == "Night-Time Scene Parsing With a Large Real Dataset")
    }

    @Test func scorerAcceptsMatchWithAuthorsAndRejectsOthers() {
        let scorer = CandidateScorer(pageText: "Night-Time Scene Parsing With a Large Real Dataset\nXin Tan, Ke Xu",
                                     guesses: ["Night-Time Scene Parsing With a Large Real Dataset"])
        var good = Metadata(title: "Night-time scene parsing with a large real dataset")
        good.authors = [Author(family: "Tan", given: "Xin")]
        #expect(scorer.evaluate(good).isAccepted)

        var other = Metadata(title: "Nighttime Semantic Segmentation with Unsupervised Learning")
        other.authors = [Author(family: "Tan", given: "Xin")]
        #expect(!scorer.evaluate(other).isAccepted)

        var erratum = Metadata(title: "Correction to: Night-Time Scene Parsing With a Large Real Dataset")
        erratum.authors = good.authors
        #expect(!scorer.evaluate(erratum).isAccepted)
    }
}
