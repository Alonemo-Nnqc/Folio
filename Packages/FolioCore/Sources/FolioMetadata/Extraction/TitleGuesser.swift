import FolioCore
import Foundation

/// Guesses the paper title from the first page layout and the embedded document title.
enum TitleGuesser {
    /// Ranked title guesses, most likely first.
    static func guesses(from facts: PDFFacts, limit: Int = 3) -> [String] {
        let pageTokens = TextMatcher.tokens(facts.firstPageText)
        var layoutGuesses = layoutCandidates(facts.firstPageLines).map(\.text)

        var result: [String] = []
        if let embedded = facts.embeddedTitle.map(clean), isTrustworthyEmbeddedTitle(embedded) {
            if pageTokens.isEmpty || TextMatcher.windowSimilarity(of: embedded, in: pageTokens) >= 0.9 {
                // Confirmed by the page itself: by far the strongest signal.
                result.append(embedded)
            } else {
                // Plausible but unconfirmed: rank it right after the best layout guess.
                layoutGuesses.insert(embedded, at: min(1, layoutGuesses.count))
            }
        }
        for guess in layoutGuesses where !result.contains(where: { TitleNormalizer.similarity($0, guess) >= 0.95 }) {
            result.append(guess)
        }
        return Array(result.prefix(limit))
    }

    // MARK: - Layout

    struct Block: Equatable {
        var text: String
        var fontSize: Double
        var order: Int
    }

    /// Blocks of consecutive same-font lines that could be a title, largest font first.
    static func layoutCandidates(_ lines: [TextLine]) -> [Block] {
        let blocks = mergeBlocks(lines)
        var candidates: [Block] = []
        for (index, block) in blocks.enumerated() {
            guard isPlausibleTitle(block.text) else { continue }
            let next = index + 1 < blocks.count ? blocks[index + 1].text.lowercased() : ""
            let previous = index > 0 ? blocks[index - 1].text.lowercased() : ""
            // Elsevier banner: "Contents lists available at ScienceDirect / <Journal> / journal homepage: …".
            if next.hasPrefix("journal homepage") || previous.contains("contents lists available") { continue }
            candidates.append(block)
        }
        return candidates.sorted { $0.fontSize != $1.fontSize ? $0.fontSize > $1.fontSize : $0.order < $1.order }
    }

    /// Merges consecutive lines that share font and size (multi-line titles) into blocks.
    static func mergeBlocks(_ lines: [TextLine]) -> [Block] {
        var blocks: [Block] = []
        var currentLines: [TextLine] = []

        func flush() {
            guard let first = currentLines.first else { return }
            blocks.append(Block(text: joinLines(currentLines.map(\.text)), fontSize: first.fontSize, order: blocks.count))
            currentLines.removeAll()
        }

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let last = currentLines.last,
               abs(last.fontSize - line.fontSize) <= 0.25, last.fontName == line.fontName, currentLines.count < 4 {
                currentLines.append(line)
            } else {
                flush()
                currentLines = [line]
            }
        }
        flush()
        return blocks
    }

    /// Joins title lines, undoing end-of-line hyphenation only where the next line continues a word.
    private static func joinLines(_ lines: [String]) -> String {
        var result = ""
        for line in lines {
            if result.isEmpty {
                result = line
            } else if result.hasSuffix("-"), let first = line.first, first.isLetter,
                      result.dropLast().last?.isLetter == true {
                // "segmen-" + "tation" is a broken word; "context-" + "aware" a compound.
                result = first.isLowercase && !isCompoundPrefix(result)
                    ? String(result.dropLast()) + line
                    : result + line
            } else {
                result += " " + line
            }
        }
        return result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "context-" + "aware" is a compound ("context-aware"), unlike "segmen-" + "tation".
    /// Without a dictionary we keep the hyphen when the fragment before it is a whole word.
    private static func isCompoundPrefix(_ text: String) -> Bool {
        let fragment = text.dropLast().split(separator: " ").last.map(String.init) ?? ""
        return fragment.count >= 4 || fragment.contains("-")
    }

    private static let bannedFragments = [
        "arxiv:", "@", "http://", "https://", "www.", "doi:", "doi.org", "©", "copyright",
        "journal homepage", "contents lists available", "open access version", "computer vision foundation",
        "identical to the accepted version", "ieee xplore", "transactions on", "journal of latex",
        "issn", "received:", "accepted:", "available online", "manuscript received", "submitted to",
        "preprint submitted", "licensed under", "creative commons", "all rights reserved",
        "full length article", "research article", "original article", "review article",
        "article info", "a r t i c l e", "a b s t r a c t", "abstract—", "abstract.", "index terms",
        "keywords:", "proceedings of", "conference on", "workshop on", "university", "institute",
        "department", "laboratory", "school of", "college of",
    ]
    private static let volumePattern = try! NSRegularExpression(pattern: #"\b(vol|no)\.\s*\d"#, options: .caseInsensitive)

    /// Rejects headers, banners, affiliations and anything that is not English prose.
    static func isPlausibleTitle(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3, words.count <= 45 else { return false }
        let visible = text.filter { !$0.isWhitespace }
        let letters = visible.filter(\.isLetter).count
        guard !visible.isEmpty, Double(letters) / Double(visible.count) >= 0.6 else { return false }
        guard TextMatcher.cjkRatio(text) <= 0.2 else { return false }
        let lower = text.lowercased()
        if bannedFragments.contains(where: lower.contains) { return false }
        let range = NSRange(location: 0, length: (text as NSString).length)
        if volumePattern.firstMatch(in: text, range: range) != nil { return false }
        return true
    }

    // MARK: - Embedded title

    static func clean(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let manuscriptCode = try! NSRegularExpression(pattern: #"^[A-Z]{2,8}[-_ ]?\d"#)

    /// Embedded titles are often junk: "Microsoft Word - draft3.docx", file names, manuscript codes.
    static func isTrustworthyEmbeddedTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        let words = title.split(separator: " ")
        guard words.count >= 3, title.count <= 400 else { return false }
        if lower.hasPrefix("microsoft ") || lower.hasPrefix("untitled") { return false }
        for suffix in [".pdf", ".doc", ".docx", ".tex", ".dvi", ".indd", ".rtf", ".ps"] where lower.contains(suffix) {
            return false
        }
        if title.contains("_"), words.count < 4 { return false }
        if lower.contains("doi") || lower.contains("http") { return false }
        let range = NSRange(location: 0, length: (title as NSString).length)
        if manuscriptCode.firstMatch(in: title, range: range) != nil { return false }
        return TextMatcher.cjkRatio(title) <= 0.2 && title.filter(\.isLetter).count >= 10
    }
}
