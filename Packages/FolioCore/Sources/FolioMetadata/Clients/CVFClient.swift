import FolioCore
import Foundation

/// What a CVF open-access PDF tells us about itself (CVPR / ICCV / WACV).
///
/// These papers carry a first-page watermark ("This CVPR paper is the Open Access version, provided by
/// the Computer Vision Foundation…"). Many are in no other open index for months after the
/// conference (Crossref waits for IEEE Xplore, not every paper is on arXiv), so Folio asks CVF directly.
struct CVFLookup: Sendable, Equatable {
    var conference: String
    var isWorkshop: Bool
    /// Years to try, most likely first.
    var years: [Int]
    var familyName: String
    var title: String
    /// Built from the PDF's own verified title/author fields; used when CVF has no page for it.
    var fallback: Metadata?

    static let booktitles = [
        "CVPR": "Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)",
        "ICCV": "Proceedings of the IEEE/CVF International Conference on Computer Vision (ICCV)",
        "WACV": "Proceedings of the IEEE/CVF Winter Conference on Applications of Computer Vision (WACV)",
    ]

    private static let watermark = try! NSRegularExpression(
        pattern: #"This\s+(CVPR|ICCV|WACV)\s*(\d{4})?\s*(workshop\s+)?paper\s+is\s+the\s+Open\s+Access\s+version"#,
        options: .caseInsensitive)
    private static let venueYear = try! NSRegularExpression(pattern: #"(CVPR|ICCV|WACV)[\s_'-]*(20\d{2})"#, options: .caseInsensitive)

    static func detect(_ facts: PDFFacts, guesses: [String], currentYear: Int = Calendar.current.component(.year, from: Date())) -> CVFLookup? {
        let page = facts.firstPageText
        let range = NSRange(page.startIndex..., in: page)
        guard let match = watermark.firstMatch(in: page, range: range),
              let conferenceRange = Range(match.range(at: 1), in: page) else { return nil }
        let conference = page[conferenceRange].uppercased()
        let isWorkshop = match.range(at: 3).location != NSNotFound

        var years: [Int] = []
        if let yearRange = Range(match.range(at: 2), in: page), let year = Int(page[yearRange]) { years.append(year) }
        for text in [facts.fileName, facts.metadataText, page] {
            let nsRange = NSRange(text.startIndex..., in: text)
            for hit in venueYear.matches(in: text, range: nsRange) {
                guard let venue = Range(hit.range(at: 1), in: text), text[venue].uppercased() == conference,
                      let yearRange = Range(hit.range(at: 2), in: text), let year = Int(text[yearRange]),
                      (2013...currentYear + 1).contains(year), !years.contains(year) else { continue }
                years.append(year)
            }
        }
        let explicitYear = years.first
        if years.isEmpty {
            // ICCV only runs in odd years.
            years = (0...2).map { currentYear - $0 }.filter { conference != "ICCV" || $0 % 2 == 1 }
        }

        guard let title = guesses.first, let family = firstAuthorFamily(facts, title: title) else { return nil }
        var lookup = CVFLookup(conference: conference, isWorkshop: isWorkshop, years: years, familyName: family, title: title)
        lookup.fallback = embeddedFallback(facts, conference: conference, year: explicitYear)
        return lookup
    }

    /// First author's family name: from the PDF's Author field, else the line under the title.
    static func firstAuthorFamily(_ facts: PDFFacts, title: String) -> String? {
        if let first = facts.embeddedAuthor?.split(whereSeparator: { $0 == ";" || $0 == "," }).first,
           let author = NameParser.author(fromDisplayName: String(first)), !author.family.isEmpty {
            return author.family
        }
        let lines = facts.firstPageLines.map(\.text)
        let normalizedTitle = TitleNormalizer.normalize(title)
        guard let titleIndex = lines.lastIndex(where: { line in
            let n = TitleNormalizer.normalize(line)
            return !n.isEmpty && normalizedTitle.hasSuffix(n)
        }), titleIndex + 1 < lines.count else { return nil }
        // "Kai Zhu1,2 Li Chen1,2, Jun Cheng3" → "Kai Zhu"
        let words = lines[titleIndex + 1].split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.filter { $0.isLetter || $0 == "-" } }.filter { !$0.isEmpty }
        return words.count >= 2 ? words[1] : nil
    }

    /// The PDF's own Title/Author fields, accepted only when both are confirmed by the page text.
    static func embeddedFallback(_ facts: PDFFacts, conference: String, year: Int?) -> Metadata? {
        guard let title = facts.embeddedTitle.map(TitleGuesser.clean), TitleGuesser.isTrustworthyEmbeddedTitle(title),
              TextMatcher.windowSimilarity(of: title, in: TextMatcher.tokens(facts.firstPageText)) >= 0.9,
              let rawAuthors = facts.embeddedAuthor else { return nil }
        let authors = rawAuthors.split(whereSeparator: { $0 == ";" }).compactMap { NameParser.author(fromDisplayName: String($0)) }
        let pageTokens = TextMatcher.tokens(facts.firstPageText)
        guard let first = authors.first, TextMatcher.containsName(first.family, in: pageTokens) else { return nil }
        var metadata = Metadata(title: title)
        metadata.type = .conferencePaper
        metadata.authors = authors
        metadata.source = booktitles[conference]
        metadata.year = year
        return metadata
    }
}

/// CVF open-access paper pages (openaccess.thecvf.com), addressed directly from title and first author.
struct CVFClient: Sendable {
    let transport: Transport

    /// Tries each candidate year (in parallel) and returns the first page that exists.
    func paper(for lookup: CVFLookup) async throws(SourceError) -> Metadata? {
        guard !lookup.isWorkshop else { return nil }
        let urls = lookup.years.compactMap { Self.url(conference: lookup.conference, year: $0, family: lookup.familyName, title: lookup.title) }
        let results = await withTaskGroup(of: Result<Metadata?, SourceError>.self) { group in
            for url in urls {
                group.addTask {
                    do throws(SourceError) {
                        guard let data = try await transport.get(url, accept: "text/html") else { return .success(nil) }
                        return .success(Self.parse(String(decoding: data, as: UTF8.self), url: url))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<Metadata?, SourceError>] = []
            for await result in group {
                if case .success(let metadata?) = result {
                    group.cancelAll()
                    return [Result<Metadata?, SourceError>.success(metadata)]
                }
                collected.append(result)
            }
            return collected
        }
        if case .success(let metadata?)? = results.first { return metadata }
        // Every year failed: surface a transient error so the caller can retry later.
        if let failure = results.lazy.compactMap({ if case .failure(let e) = $0 { e } else { nil } }).first(where: \.isTransient) {
            throw failure
        }
        return nil
    }

    /// `…/content/CVPR2026/html/Zhu_Dual-level_Adapter_…_CVPR_2026_paper.html` (2021+);
    /// `…/content_CVPR_2020/html/…_CVPR_2020_paper.html` before that.
    static func url(conference: String, year: Int, family: String, title: String) -> URL? {
        let familySlug = slugWords(family).joined(separator: "_")
        let titleSlug = slugWords(title).prefix(10).joined(separator: "_")
        guard !familySlug.isEmpty, !titleSlug.isEmpty else { return nil }
        let file = "\(familySlug)_\(titleSlug)_\(conference)_\(year)_paper.html"
        let folder = year >= 2021 ? "content/\(conference)\(year)" : "content_\(conference)_\(year)"
        return URL(string: "https://openaccess.thecvf.com/\(folder)/html/\(file)")
    }

    /// CVF slugs keep letters, digits and hyphens, drop other punctuation and strip accents.
    static func slugWords(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split(whereSeparator: \.isWhitespace).map { word in
            String(word.filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" })
        }.filter { !$0.isEmpty && $0 != "-" }
    }

    /// Reads title, authors, booktitle, year and pages from the page's BibTeX, plus the abstract.
    static func parse(_ html: String, url: URL) -> Metadata? {
        guard let bib = firstMatch(#"<div class="bibref[^"]*">(.*?)</div>"#, in: html) else { return nil }
        func field(_ name: String) -> String? {
            firstMatch("\(name)\\s*=\\s*\\{(.*?)\\},?\\s*\\n", in: bib + "\n")
                .map { FieldNormalizer.cleanText($0) ?? $0 }
        }
        guard let title = FieldNormalizer.cleanTitle(field("title")) else { return nil }
        var metadata = Metadata(title: title)
        metadata.type = .conferencePaper
        metadata.authors = (field("author") ?? "").components(separatedBy: " and ")
            .compactMap { NameParser.author(fromDisplayName: $0) }
        metadata.source = field("booktitle")
        metadata.year = field("year").flatMap { Int($0) }
        metadata.date = metadata.year.map(String.init)
        metadata.pages = FieldNormalizer.normalizePages(field("pages"))
        metadata.url = url.absoluteString
        metadata.abstract = firstMatch(#"<div id="abstract">(.*?)</div>"#, in: html).flatMap(FieldNormalizer.cleanAbstract)
        return metadata
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
