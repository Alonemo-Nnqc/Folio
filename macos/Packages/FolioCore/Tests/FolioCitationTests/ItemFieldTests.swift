import Foundation
import FolioCore
import Testing

@testable import FolioCitation

/// #19: books, chapters and theses cite with their own fields.
struct ItemFieldCitationTests {
    static let book: CitationEntry = {
        var m = Metadata(title: "光学原理")
        m.type = .book
        m.authors = [Author(family: "玻恩"), Author(family: "沃尔夫")]
        m.translators = [Author(family: "杨葭荪")]
        m.publisher = "电子工业出版社"
        m.place = "北京"
        m.edition = "第7版"
        m.year = 2009
        return CitationEntry(id: "1", citationKey: "born2009", metadata: m)
    }()

    static let thesis: CitationEntry = {
        var m = Metadata(title: "基于图神经网络的分割方法研究")
        m.type = .thesis
        m.authors = [Author(family: "李", given: "伟")]
        m.source = "北京航空航天大学"
        m.place = "北京"
        m.genre = "硕士学位论文"
        m.year = 2024
        return CitationEntry(id: "2", citationKey: "li2024", metadata: m)
    }()

    static let chapter: CitationEntry = {
        var m = Metadata(title: "Optical Flow")
        m.type = .bookChapter
        m.authors = [Author(family: "Horn", given: "Berthold")]
        m.source = "Handbook of Computer Vision"
        m.editors = [Author(family: "Jähne", given: "Bernd"), Author(family: "Haussecker", given: "Horst")]
        m.publisher = "Academic Press"
        m.place = "San Diego"
        m.pages = "397-422"
        m.year = 1999
        return CitationEntry(id: "3", citationKey: "horn1999", metadata: m)
    }()

    @Test func gbt7714CitesPlaceAndPublisherOfBooksAndTheses() throws {
        let renderer = try CSLRenderer()
        let text = try renderer.render([Self.book, Self.thesis], style: .gbt7714).plainText
        #expect(text.contains("[M]"), "\(text)")
        #expect(text.contains("北京: 电子工业出版社"), "\(text)")
        #expect(text.contains("[D]"), "\(text)")
        #expect(text.contains("北京: 北京航空航天大学"), "the university is the thesis's publisher, not a container: \(text)")
    }

    @Test func cslJSONCarriesTheFields() {
        let book = CSLJSONMapper.csljson(id: "b", metadata: Self.book.metadata)
        #expect(book["publisher-place"] as? String == "北京")
        #expect(book["edition"] as? String == "第7版")
        #expect((book["translator"] as? [[String: String]])?.first?["literal"] == "杨葭荪")
        #expect(book["container-title"] == nil)
        let thesis = CSLJSONMapper.csljson(id: "t", metadata: Self.thesis.metadata)
        #expect(thesis["publisher"] as? String == "北京航空航天大学")
        #expect(thesis["genre"] as? String == "硕士学位论文")
        #expect(thesis["container-title"] == nil)
        let chapter = CSLJSONMapper.csljson(id: "c", metadata: Self.chapter.metadata)
        #expect(chapter["container-title"] as? String == "Handbook of Computer Vision")
        #expect((chapter["editor"] as? [[String: String]])?.count == 2)
    }

    @Test func bibtexWritesTheFields() {
        let thesis = BibTeXWriter.entry(Self.thesis)
        #expect(thesis.hasPrefix("@mastersthesis{"), "\(thesis)")
        #expect(thesis.contains("school = {北京航空航天大学}") && thesis.contains("address = {北京}") && thesis.contains("type = {硕士学位论文}"))
        let book = BibTeXWriter.entry(Self.book)
        #expect(book.contains("edition = {第7版}") && book.contains("translator = {杨葭荪}") && book.contains("address = {北京}"))
        let chapter = BibTeXWriter.entry(Self.chapter)
        #expect(chapter.contains("editor = {Jähne, Bernd and Haussecker, Horst}") && chapter.contains("booktitle = {Handbook of Computer Vision}"))
    }

    /// What is exported comes back the same, in each format.
    @Test(arguments: ReferenceFormat.allCases)
    func fieldsRoundTrip(format: ReferenceFormat) {
        let entries = [Self.book, Self.thesis, Self.chapter]
        let records = ReferenceReader.parse(format.render(entries))
        #expect(records.count == 3)
        for (record, entry) in zip(records, entries) {
            let m = record.metadata, e = entry.metadata
            #expect(m.type == e.type, "\(format) \(e.title)")
            #expect(m.place == e.place, "\(format) \(e.title): \(m.place ?? "nil")")
            #expect(m.edition == e.edition, "\(format) \(e.title)")
            #expect(m.editors == e.editors, "\(format) \(e.title): \(m.editors)")
            #expect(m.translators == e.translators, "\(format) \(e.title): \(m.translators)")
            #expect(m.genre == e.genre, "\(format) \(e.title)")
            #expect(m.source == e.source, "\(format) \(e.title): \(m.source ?? "nil")")
            #expect(m.publisher == e.publisher, "\(format) \(e.title): \(m.publisher ?? "nil")")
        }
    }
}
