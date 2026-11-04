import FolioCore
import Foundation

/// Decides whether a record returned by a source really is the PDF at hand.
///
/// A wrong match is worse than no match, so every rule errs on the side of rejecting.
struct CandidateScorer: Sendable {
    /// Title similarity needed when at least one of the first three authors appears on page one.
    static let acceptWithAuthors = 0.90
    /// Title similarity that is enough on its own.
    static let acceptTitleOnly = 0.97
    /// Minimum similarity between an identifier lookup's title and page one.
    static let identifierMinimum = 0.85
    /// Shorter titles are too generic to be matched against arbitrary runs of page text.
    static let minimumWindowTokens = 4

    struct Evaluation: Sendable, Equatable {
        /// Best similarity against the title guesses.
        var guessSimilarity: Double
        /// Best similarity against runs of first-page text.
        var pageSimilarity: Double
        var authorsFound: Bool
        var isEditorialNotice: Bool
        var titleTokenCount: Int

        var titleSimilarity: Double { max(guessSimilarity, pageSimilarity) }

        var isAccepted: Bool {
            guard !isEditorialNotice else { return false }
            if titleSimilarity >= CandidateScorer.acceptWithAuthors && authorsFound { return true }
            // Without author support the title must be long enough to be unambiguous.
            if guessSimilarity >= CandidateScorer.acceptTitleOnly && titleTokenCount >= 4 { return true }
            return pageSimilarity >= CandidateScorer.acceptTitleOnly && titleTokenCount >= 6
        }
    }

    let guesses: [String]
    let pageTokens: [String]

    init(pageText: String, guesses: [String]) {
        self.guesses = guesses
        pageTokens = TextMatcher.tokens(pageText)
    }

    func evaluate(_ metadata: Metadata) -> Evaluation {
        let titleTokens = TextMatcher.tokens(metadata.title)
        let guess = guesses.map { TitleNormalizer.similarity($0, metadata.title) }.max() ?? 0
        let page = titleTokens.count >= Self.minimumWindowTokens
            ? TextMatcher.windowSimilarity(of: metadata.title, in: pageTokens)
            : 0
        return Evaluation(guessSimilarity: guess, pageSimilarity: page,
                          authorsFound: authorsAppear(metadata.authors),
                          isEditorialNotice: isUnexpectedEditorialNotice(metadata.title),
                          titleTokenCount: titleTokens.count)
    }

    /// Identifier lookups need their title on page one, which rejects DOIs of cited works.
    /// For self-describing identifiers (arXiv stamp, the PDF's own metadata) the title may
    /// legitimately have changed between versions, so matching authors are accepted instead.
    func verifiesIdentifierResult(_ metadata: Metadata, selfDescribing: Bool) -> Bool {
        let evaluation = evaluate(metadata)
        if evaluation.isEditorialNotice { return false }
        if evaluation.titleSimilarity >= Self.identifierMinimum { return true }
        return selfDescribing && evaluation.authorsFound
    }

    /// Fields Zotero's recognizer read off the page trivially "appear on the page" — it has been seen
    /// to hand back the author line as the title — so they must also agree with the engine's own
    /// best title guess. (Lower-ranked guesses can themselves be author lines.)
    func acceptsRecognizedFields(_ metadata: Metadata) -> Bool {
        guard let best = guesses.first, TitleNormalizer.similarity(best, metadata.title) >= Self.acceptWithAuthors else {
            return false
        }
        return evaluate(metadata).isAccepted
    }

    /// True when one of the first three authors' family names occurs on page one.
    func authorsAppear(_ authors: [Author]) -> Bool {
        for author in authors.prefix(3) {
            let family = author.family.trimmingCharacters(in: .whitespaces)
            guard !family.isEmpty else { continue }
            if TextMatcher.containsName(family, in: pageTokens) { return true }
            // Some records swap given and family names (common for Chinese names).
            if !author.given.isEmpty, TextMatcher.containsName(author.given, in: pageTokens),
               TextMatcher.tokens(family).allSatisfy({ token in pageTokens.contains { $0.hasPrefix(token) } }) {
                return true
            }
        }
        return false
    }

    private static let noticePrefixes = [
        "correction", "corrigendum", "erratum", "errata", "retraction", "retracted", "expression of concern",
        "reply to", "response to", "comment on", "comments on", "author correction", "publisher correction",
        "withdrawn", "withdrawal", "notice of", "editorial", "review of",
    ]

    /// Corrections and replies repeat the original title plus a few words, which would otherwise
    /// score just above the threshold.
    private func isUnexpectedEditorialNotice(_ title: String) -> Bool {
        let normalized = TitleNormalizer.normalize(title)
        guard let prefix = Self.noticePrefixes.first(where: { normalized.hasPrefix($0) }) else { return false }
        return !guesses.contains { TitleNormalizer.normalize($0).hasPrefix(prefix) }
    }
}
