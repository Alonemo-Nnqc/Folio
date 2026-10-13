import FolioCore
import Testing

@testable import FolioCitation

struct CSLRendererTests {
    @Test func gbt7714FormatsAuthorsAndJournalLabel() throws {
        let renderer = try CSLRenderer()
        let output = try renderer.render([Fixtures.fourAuthorJournalArticle], style: .gbt7714)
        #expect(output.plainText.contains("ZHANG T, GAO F, QI L, et al."))
        #expect(output.plainText.contains("[J]"))
        #expect(output.html == nil)
        // No numeric bibliography label should remain.
        #expect(!output.plainText.hasPrefix("["))
    }

    @Test func apaFormatsAuthorsAndYear() throws {
        let renderer = try CSLRenderer()
        let output = try renderer.render([Fixtures.fourAuthorJournalArticle], style: .apa)
        #expect(output.plainText.contains("Zhang, T., Gao, F."))
        #expect(output.plainText.contains("(2026)"))
        #expect(output.html != nil)
        #expect(output.html?.contains("<i>") == true)
    }

    @Test func bibtexStyleDelegatesToBibTeXWriter() throws {
        let renderer = try CSLRenderer()
        let output = try renderer.render([Fixtures.journalArticle], style: .bibtex)
        #expect(output.plainText == BibTeXWriter.document([Fixtures.journalArticle]))
        #expect(output.html == nil)
    }

    @Test func renderingOneHundredTimesIsFast() throws {
        let renderer = try CSLRenderer()
        let entries = [Fixtures.journalArticle, Fixtures.conferencePaper, Fixtures.arxivPreprint]

        // Warm up: the first render for a style parses that style's CSL and
        // builds its CSL.Engine, which is then cached (documented one-time
        // cost). The performance budget below is for the steady-state
        // per-render cost with an already-warmed renderer.
        _ = try renderer.render(entries, style: .apa)

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for _ in 0..<100 {
                _ = try renderer.render(entries, style: .apa)
            }
        }
        #expect(elapsed < .seconds(1))
    }

    @Test(arguments: CitationStyle.allCases.filter { $0 != .bibtex })
    func everyStyleRendersABibliography(style: CitationStyle) throws {
        let renderer = try CSLRenderer()
        let entries = [Fixtures.journalArticle, Fixtures.conferencePaper]
        let output = try renderer.render(entries, style: style)
        let lines = output.plainText.components(separatedBy: "\n")
        #expect(lines.count == 2, "\(style): \(output.plainText)")
        #expect(output.plainText.contains("UNet Architecture"), "\(style)")
        #expect(!output.plainText.contains("\t"))
        #expect((output.html != nil) == (style != .gbt7714))
    }

    @Test func numericStylesKeepTheirLabelsWithASpace() throws {
        let renderer = try CSLRenderer()
        let ieee = try renderer.render([Fixtures.journalArticle, Fixtures.conferencePaper], style: .ieee)
        #expect(ieee.plainText.hasPrefix("[1] "), "\(ieee.plainText)")
        #expect(ieee.plainText.contains("\n[2] "))
        #expect(ieee.plainText.contains("T. Zhang and F. Gao"))
    }

    @Test func inTextCitations() throws {
        let renderer = try CSLRenderer()
        let entries = [Fixtures.journalArticle, Fixtures.conferencePaper]
        let apa = try renderer.inTextCitations(entries, style: .apa)
        #expect(apa.each == ["(Zhang & Gao, 2026)", "(Qi, 2025)"])
        #expect(apa.combined == "(Qi, 2025; Zhang & Gao, 2026)")
        let ieee = try renderer.inTextCitations(entries, style: .ieee)
        #expect(ieee.each == ["[1]", "[2]"])
        let bib = try renderer.inTextCitations(entries, style: .bibtex)
        #expect(bib.combined == "\\cite{zhang2026,qi2025}")
        // Rendering in another style in between does not disturb a cached engine.
        #expect(try renderer.inTextCitations(entries, style: .apa).each == apa.each)
    }

    @Test func styleNamesFromAgents() {
        #expect(CitationStyle.named("GB/T 7714") == .gbt7714)
        #expect(CitationStyle.named("APA") == .apa)
        #expect(CitationStyle.named("Chicago") == .chicago)
        #expect(CitationStyle.named("mla9") == .mla)
        #expect(CitationStyle.named("nlm") == .vancouver)
        #expect(CitationStyle.named("unknown") == nil)
    }
}
