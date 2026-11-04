import FolioCitation
import FolioCore
import Testing

/// CITE-01/02: the app's citation actor renders all three styles.
@Suite struct CitationServiceTests {
    func entry() -> CitationEntry {
        var m = Metadata(title: "Night-Time Scene Parsing With a Large Real Dataset")
        m.authors = [Author(family: "Tan", given: "Xin"), Author(family: "Xu", given: "Ke"), Author(family: "Cao", given: "Ying"),
                     Author(family: "Zhang", given: "Ling")]
        m.year = 2021
        m.source = "IEEE Transactions on Image Processing"
        m.volume = "30"
        m.pages = "9085-9098"
        m.doi = "10.1109/tip.2021.3122004"
        return CitationEntry(id: "1", citationKey: "tan2021", metadata: m)
    }

    @Test func rendersAllStyles() async throws {
        let service = CitationService()
        let bib = try await service.render([entry()], style: .bibtex)
        #expect(bib.plainText.hasPrefix("@article{tan2021,"))
        let gbt = try await service.render([entry()], style: .gbt7714)
        #expect(gbt.plainText.contains("TAN X, XU K, CAO Y, et al."))
        // GB/T 7714-2015 marks journal articles reachable online (DOI) as [J/OL].
        #expect(gbt.plainText.contains("[J/OL]"))
        #expect(gbt.plainText.contains("2021, 30: 9085-9098"))
        let apa = try await service.render([entry()], style: .apa)
        #expect(apa.plainText.contains("Tan, X., Xu, K., Cao, Y., & Zhang, L. (2021)."))
        #expect(apa.html?.contains("<i>") ?? false)
    }
}
