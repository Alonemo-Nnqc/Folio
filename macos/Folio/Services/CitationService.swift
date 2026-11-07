import FolioCitation
import FolioCore
import Foundation

/// Owns the citeproc renderer (a JavaScriptCore context) on its own actor.
actor CitationService {
    private var renderer: CSLRenderer?

    func render(_ entries: [CitationEntry], style: CitationStyle) throws -> CitationOutput {
        if style == .bibtex {
            return CitationOutput(plainText: BibTeXWriter.document(entries), html: nil)
        }
        if renderer == nil { renderer = try CSLRenderer() }
        return try renderer!.render(entries, style: style)
    }

    /// Parses the styles ahead of time so the first "复制引用" is instant (APA takes ~1 s cold).
    func warmUp() {
        var sample = Metadata(title: "Warm up")
        sample.authors = [Author(family: "Folio", given: "A")]
        sample.year = 2026
        let entry = CitationEntry(id: "warmup", citationKey: "folio2026", metadata: sample)
        _ = try? render([entry], style: .apa)
        _ = try? render([entry], style: .gbt7714)
    }
}
