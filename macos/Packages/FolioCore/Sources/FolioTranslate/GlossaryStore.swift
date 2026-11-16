import Foundation

/// A term of the glossary Folio keeps (设置 ▸ 翻译 ▸ 术语表): how a term of the field is translated, for every paper
/// translated into that language from then on.
public struct GlossaryTerm: Codable, Sendable, Hashable, Identifiable {
    public enum Origin: String, Codable, Sendable { case user, extracted }

    public var id: UUID
    public var source: String
    public var target: String
    /// The language the term is translated into (`zh`, `ja` …), as in the translation options.
    public var language: String
    /// Typed (or imported) by the user, or found by a model in a paper while translating it.
    public var origin: Origin
    /// The paper a model found it in.
    public var paper: String?
    public var added: Date
    /// Off: kept in the list, not given to the translator.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), source: String, target: String, language: String, origin: Origin = .user, paper: String? = nil,
                added: Date = Date(), isEnabled: Bool = true) {
        self.id = id
        self.source = source
        self.target = target
        self.language = language
        self.origin = origin
        self.paper = paper
        self.added = added
        self.isEnabled = isEnabled
    }
}

/// The glossary on disk: terms the user wrote and terms models found in the papers translated so far, by language.
/// A translation gets the terms of its language that occur in the text; what the user wrote or changed always wins
/// over what a model finds later.
public final class GlossaryStore: @unchecked Sendable {
    /// The app's glossary, beside the translation cache.
    public static let shared = GlossaryStore(url: TranslationJob.supportDirectory.appending(path: "glossary.json"))

    private let url: URL
    private let lock = NSLock()
    private var loaded: [GlossaryTerm]?

    public init(url: URL) { self.url = url }

    /// Languages written differently are one glossary ("zh-CN" and "zh"; "zh-TW" and "zh-Hant").
    static func key(_ language: String) -> String {
        switch language.lowercased() {
        case "zh", "zh-cn", "zh-hans", "zh-sg": "zh"
        case "zh-tw", "zh-hk", "zh-hant": "zh-tw"
        default: language.lowercased()
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).compare(b.trimmingCharacters(in: .whitespaces), options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
    }

    private func all() -> [GlossaryTerm] {
        if let loaded { return loaded }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let terms = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([GlossaryTerm].self, from: $0) } ?? []
        loaded = terms
        return terms
    }

    private func save(_ terms: [GlossaryTerm]) {
        loaded = terms
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(terms) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The terms of `language` (nil: of every language), in the order they were added.
    public func terms(language: String? = nil) -> [GlossaryTerm] {
        lock.withLock { all().filter { language == nil || Self.key($0.language) == Self.key(language!) } }
    }

    /// What a translation into `language` is given: the terms switched on.
    public func entries(for language: String) -> [GlossaryEntry] {
        terms(language: language).filter(\.isEnabled).map { GlossaryEntry(source: $0.source, target: $0.target) }
    }

    /// Adds a term, or changes the one with its id; a term whose source is already there in that language replaces it.
    /// Empty sources and targets are not kept.
    @discardableResult
    public func save(_ term: GlossaryTerm) -> GlossaryTerm? {
        var term = term
        term.source = term.source.trimmingCharacters(in: .whitespacesAndNewlines)
        term.target = term.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.source.isEmpty, !term.target.isEmpty else { return nil }
        return lock.withLock {
            var terms = all()
            terms.removeAll { $0.id != term.id && Self.key($0.language) == Self.key(term.language) && Self.same($0.source, term.source) }
            if let index = terms.firstIndex(where: { $0.id == term.id }) { terms[index] = term } else { terms.append(term) }
            save(terms)
            return term
        }
    }

    public func remove(_ ids: Set<UUID>) {
        lock.withLock { save(all().filter { !ids.contains($0.id) }) }
    }

    /// Terms a model found in `paper`: those not in the glossary yet are added (what is there stays as it is, switched
    /// off or changed by the user included). Returns how many were new.
    @discardableResult
    public func learn(_ entries: [GlossaryEntry], language: String, paper: String?) -> Int {
        lock.withLock {
            var terms = all()
            var added = 0
            for entry in entries {
                let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines), target = entry.target.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty, !target.isEmpty, source.count < 80, !Self.same(source, target),
                      !terms.contains(where: { Self.key($0.language) == Self.key(language) && Self.same($0.source, source) }) else { continue }
                terms.append(GlossaryTerm(source: source, target: target, language: language, origin: .extracted, paper: paper))
                added += 1
            }
            if added > 0 { save(terms) }
            return added
        }
    }

    /// Terms from a CSV file (`source,target` a line; a header line and further columns are ignored), as the user's own.
    /// Returns how many lines became terms.
    @discardableResult
    public func importCSV(_ file: URL, language: String) -> Int {
        var count = 0
        for entry in TranslationJob.readGlossary(file) where save(GlossaryTerm(source: entry.source, target: entry.target, language: language)) != nil {
            count += 1
        }
        return count
    }

    /// The terms of `language` as CSV (`source,target`), for another computer or another program.
    public func exportCSV(language: String) -> String {
        func field(_ text: String) -> String { text.contains(",") || text.contains("\"") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text }
        return "source,target\n" + terms(language: language).map { field($0.source) + "," + field($0.target) }.joined(separator: "\n") + "\n"
    }
}
