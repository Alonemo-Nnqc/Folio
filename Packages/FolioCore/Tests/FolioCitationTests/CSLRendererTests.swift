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
}
