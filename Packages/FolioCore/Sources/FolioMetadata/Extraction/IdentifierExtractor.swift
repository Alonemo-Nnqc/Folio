import Foundation

/// Where in the PDF an identifier was found, in priority order.
enum IdentifierLocation: Int, Sendable, Comparable {
    case firstPage, secondPage, fileName, metadata

    static func < (lhs: IdentifierLocation, rhs: IdentifierLocation) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// An identifier found in a PDF.
struct FoundIdentifier: Sendable, Equatable {
    var identifier: Identifier
    var location: IdentifierLocation
    /// The identifier names this very document (arXiv side stamp, DOI in the PDF's own metadata)
    /// rather than possibly a cited work.
    var isSelfDescribing: Bool
}

/// Finds DOIs, arXiv IDs and ISBNs in PDF text, file names and metadata.
enum IdentifierExtractor {
    /// All identifiers, ordered first page > second page > file name > metadata (then by position).
    static func extract(from facts: PDFFacts) -> [FoundIdentifier] {
        var found: [FoundIdentifier] = []

        func add(_ identifier: Identifier, _ location: IdentifierLocation, selfDescribing: Bool) {
            if let index = found.firstIndex(where: { $0.identifier == identifier }) {
                found[index].isSelfDescribing = found[index].isSelfDescribing || selfDescribing
            } else {
                found.append(FoundIdentifier(identifier: identifier, location: location, isSelfDescribing: selfDescribing))
            }
        }

        func scan(_ text: String, _ location: IdentifierLocation, selfDescribing: Bool) {
            guard !text.isEmpty else { return }
            let stamps = Set(arxivStampIDs(in: text))
            var hits: [(offset: Int, identifier: Identifier, selfDescribing: Bool)] = []
            for (offset, doi) in matches(doiPattern, in: text).compactMap({ m in cleanDOI(m.text).map { (m.offset, $0) } }) {
                hits.append((offset, .doi(doi), selfDescribing))
            }
            for match in arxivMatches(in: text, requireContext: true) {
                hits.append((match.offset, .arxiv(match.id), selfDescribing || stamps.contains(match.id)))
            }
            for match in isbnMatches(in: text, requireKeyword: true) {
                hits.append((match.offset, .isbn(match.isbn), selfDescribing))
            }
            for hit in hits.sorted(by: { $0.offset < $1.offset }) {
                add(hit.identifier, location, selfDescribing: hit.selfDescribing)
            }
        }

        scan(facts.firstPageText, .firstPage, selfDescribing: false)
        scan(facts.secondPageText, .secondPage, selfDescribing: false)

        let name = (facts.fileName as NSString).deletingPathExtension
        for doi in fileNameDOIs(name) { add(.doi(doi), .fileName, selfDescribing: false) }
        for id in arxivIDs(in: name, requireContext: false) { add(.arxiv(id), .fileName, selfDescribing: false) }

        scan(facts.metadataText, .metadata, selfDescribing: true)

        return found.sorted { $0.location < $1.location }
    }

    // MARK: - DOI

    private static let doiPattern = try! NSRegularExpression(pattern: #"10\.\d{4,9}/[^\s"<>]+"#)

    static func dois(in text: String) -> [String] {
        unique(matches(doiPattern, in: text).compactMap { cleanDOI($0.text) })
    }

    /// Strips trailing punctuation that is not part of the DOI and lowercases it.
    static func cleanDOI(_ raw: String) -> String? {
        var doi = Substring(raw)
        while let last = doi.last {
            if ".,;:'\"".contains(last) {
                doi.removeLast()
            } else if last == ")", doi.count(where: { $0 == "(" }) < doi.count(where: { $0 == ")" }) {
                doi.removeLast()
            } else if last == "]", doi.count(where: { $0 == "[" }) < doi.count(where: { $0 == "]" }) {
                doi.removeLast()
            } else {
                break
            }
        }
        guard let slash = doi.firstIndex(of: "/"), doi.index(after: slash) < doi.endIndex else { return nil }
        return doi.lowercased()
    }

    /// File names cannot contain "/", so DOIs there are often written with "_" instead.
    private static func fileNameDOIs(_ name: String) -> [String] {
        let direct = dois(in: name)
        if !direct.isEmpty { return direct }
        guard let range = name.range(of: #"10\.\d{4,9}_\S+"#, options: .regularExpression) else { return [] }
        var candidate = String(name[range])
        if let underscore = candidate.firstIndex(of: "_") {
            candidate.replaceSubrange(underscore...underscore, with: "/")
        }
        return cleanDOI(candidate).map { [$0] } ?? []
    }

    /// "10.48550/arxiv.2405.02717" -> "2405.02717".
    static func arxivID(fromDOI doi: String) -> String? {
        let prefix = "10.48550/arxiv."
        guard doi.lowercased().hasPrefix(prefix) else { return nil }
        let id = String(doi.dropFirst(prefix.count))
        return arxivIDs(in: id, requireContext: false).first
    }

    // MARK: - arXiv

    private static let modernID = #"(\d{4}\.\d{4,5})(?:v\d+)?"#
    private static let legacyID = #"([a-z][a-z\-]*(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?"#
    private static let contextualPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i:arxiv)\s*[:.]?\s*"# + modernID + #"(?!\d)"#),
        try! NSRegularExpression(pattern: #"(?i:arxiv\.org/(?:abs|pdf)/)"# + modernID + #"(?!\d)"#),
        try! NSRegularExpression(pattern: #"(?i:arxiv)\s*:\s*"# + legacyID + #"(?!\d)"#),
        try! NSRegularExpression(pattern: #"(?i:arxiv\.org/(?:abs|pdf)/)"# + legacyID + #"(?!\d)"#),
    ]
    private static let bareModern = try! NSRegularExpression(pattern: #"(?<![\d.])"# + modernID + #"(?![\d])"#)
    private static let barePattern = try! NSRegularExpression(pattern: #"^(?:"# + modernID + "|" + legacyID + #")$"#)
    /// The vertical stamp arXiv prints on every page one: "arXiv:2412.08345v1 [eess.IV] 11 Dec 2024".
    private static let stampPattern = try! NSRegularExpression(
        pattern: #"arXiv:(\d{4}\.\d{4,5}|[a-z][a-z\-]*(?:\.[A-Z]{2})?/\d{7})v\d+\s*\[[A-Za-z.\-]+\]"#)

    static func arxivIDs(in text: String, requireContext: Bool) -> [String] {
        unique(arxivMatches(in: text, requireContext: requireContext).map(\.id))
    }

    static func arxivStampIDs(in text: String) -> [String] {
        unique(matches(stampPattern, in: text, group: 1).map(\.text).filter(isPlausibleArxivID))
    }

    static func isBareArxivID(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !matches(barePattern, in: trimmed).isEmpty
    }

    private static func arxivMatches(in text: String, requireContext: Bool) -> [(offset: Int, id: String)] {
        let patterns = requireContext ? contextualPatterns : [bareModern]
        return patterns
            .flatMap { matches($0, in: text, group: 1) }
            .filter { isPlausibleArxivID($0.text) }
            .sorted { $0.offset < $1.offset }
            .map { ($0.offset, $0.text) }
    }

    /// Checks the YYMM prefix of modern IDs (4-digit numbers until 2014, 5-digit since 2015).
    private static func isPlausibleArxivID(_ id: String) -> Bool {
        guard let dot = id.firstIndex(of: "."), !id.contains("/") else { return id.contains("/") }
        let prefix = id[..<dot]
        let number = id[id.index(after: dot)...]
        guard let yymm = Int(prefix), let month = Int(prefix.suffix(2)), (1...12).contains(month) else { return false }
        let year = yymm / 100
        guard year >= 7 else { return false }
        return number.count == 4 ? yymm <= 1412 : yymm >= 1501
    }

    // MARK: - ISBN

    private static let keywordISBN = try! NSRegularExpression(
        pattern: #"ISBN(?:-1[03])?\s*:?\s*([0-9][0-9\-\s]{8,18}[0-9Xx])"#, options: [.caseInsensitive])
    private static let bareISBN = try! NSRegularExpression(
        pattern: #"(?<![\dXx])((?:97[89][\-\s]?)?(?:\d[\-\s]?){9}[\dXx])(?![\dXx])"#)

    static func isbns(in text: String, requireKeyword: Bool) -> [String] {
        unique(isbnMatches(in: text, requireKeyword: requireKeyword).map(\.isbn))
    }

    private static func isbnMatches(in text: String, requireKeyword: Bool) -> [(offset: Int, isbn: String)] {
        let pattern = requireKeyword ? keywordISBN : bareISBN
        return matches(pattern, in: text, group: 1).compactMap { match in
            let compact = match.text.uppercased().filter { $0.isNumber || $0 == "X" }
            for length in [13, 10] where compact.count >= length {
                let candidate = String(compact.prefix(length))
                if isValidISBN(candidate) { return (match.offset, candidate) }
            }
            return nil
        }
    }

    /// Validates the check digit of a separator-free ISBN-10 or ISBN-13.
    static func isValidISBN(_ isbn: String) -> Bool {
        let characters = Array(isbn.uppercased())
        switch characters.count {
        case 10:
            var sum = 0
            for (index, character) in characters.enumerated() {
                let value: Int
                if let digit = character.wholeNumberValue {
                    value = digit
                } else if character == "X", index == 9 {
                    value = 10
                } else {
                    return false
                }
                sum += value * (10 - index)
            }
            return sum % 11 == 0
        case 13:
            var sum = 0
            for (index, character) in characters.enumerated() {
                guard let digit = character.wholeNumberValue else { return false }
                sum += digit * (index.isMultiple(of: 2) ? 1 : 3)
            }
            return sum % 10 == 0 && (isbn.hasPrefix("978") || isbn.hasPrefix("979"))
        default:
            return false
        }
    }

    // MARK: - Regex plumbing

    private struct Match {
        var offset: Int
        var text: String
    }

    private static func matches(_ regex: NSRegularExpression, in text: String, group: Int = 0) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { result in
            let range = result.range(at: group)
            guard range.location != NSNotFound else { return nil }
            return Match(offset: range.location, text: ns.substring(with: range))
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
