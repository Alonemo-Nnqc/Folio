import FolioCore
import Foundation

/// Reference interchange formats (AI-06): BibTeX and RIS in, RIS and CSL JSON out.
public enum ReferenceFormat: String, Sendable, CaseIterable {
    case bibtex, ris, csljson

    public var displayName: String {
        switch self {
        case .bibtex: "BibTeX"
        case .ris: "RIS"
        case .csljson: "CSL JSON"
        }
    }

    public var fileExtension: String {
        switch self {
        case .bibtex: "bib"
        case .ris: "ris"
        case .csljson: "json"
        }
    }

    /// Guesses the format of pasted or file text.
    public static func detect(_ text: String) -> ReferenceFormat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^TY  - "#, options: [.regularExpression, .anchored]) != nil
            || trimmed.contains("\nTY  - ") { return .ris }
        if trimmed.range(of: #"@[A-Za-z]+\s*[\{\(]"#, options: .regularExpression) != nil { return .bibtex }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") { return .csljson }
        return nil
    }

    /// Renders entries in this format.
    public func render(_ entries: [CitationEntry]) -> String {
        switch self {
        case .bibtex: BibTeXWriter.document(entries)
        case .ris: RISWriter.document(entries)
        case .csljson: CSLJSONWriter.document(entries)
        }
    }
}

/// Parses references; a `ReferenceRecord` keeps the original key so imports can reuse it.
public struct ReferenceRecord: Sendable, Hashable {
    public var metadata: Metadata
    public var citationKey: String?
    public var keywords: [String]
}

public enum ReferenceReader {
    /// Parses BibTeX, RIS or CSL JSON (detected automatically). Unparseable entries are skipped.
    public static func parse(_ text: String) -> [ReferenceRecord] {
        switch ReferenceFormat.detect(text) {
        case .bibtex: BibTeXReader.parse(text)
        case .ris: RISReader.parse(text)
        case .csljson: CSLJSONReader.parse(text)
        case nil: []
        }
    }
}

// MARK: - BibTeX

enum BibTeXReader {
    static func parse(_ text: String) -> [ReferenceRecord] {
        var records: [ReferenceRecord] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "@" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j].isLetter { j += 1 }
            let kind = String(chars[(i + 1)..<j]).lowercased()
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count, chars[j] == "{" || chars[j] == "(" else { i = j; continue }
            // Find the end of the entry: the matching "}" for @type{…}, or ")" for @type(…).
            let open = chars[j], close: Character = open == "{" ? "}" : ")"
            var depth = 0, braces = 0, k = j
            repeat {
                let c = chars[k]
                if open == "{" {
                    if c == "{" { depth += 1 } else if c == "}" { depth -= 1 }
                } else {
                    if c == "{" { braces += 1 } else if c == "}" { braces -= 1 }
                    else if braces == 0 && c == "(" { depth += 1 } else if braces == 0 && c == close { depth -= 1 }
                }
                k += 1
            } while k < chars.count && depth > 0
            let body = String(chars[(j + 1)..<max(j + 1, k - 1)])
            i = k
            guard !["comment", "string", "preamble"].contains(kind) else { continue }
            if let record = entry(kind: kind, body: body) { records.append(record) }
        }
        return records
    }

    private static func entry(kind: String, body: String) -> ReferenceRecord? {
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let key = body[..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = parseFields(String(body[body.index(after: comma)...]))
        guard let title = fields["title"].map(clean), !title.isEmpty else { return nil }
        var m = Metadata(title: title)
        m.type = itemType(kind, fields: fields)
        m.authors = (fields["author"] ?? fields["editor"]).map(authors) ?? []
        if let year = fields["year"].flatMap({ Int(clean($0).prefix(4)) }) { m.year = year }
        if let date = fields["date"].map(clean), !date.isEmpty {
            m.date = date
            if m.year == nil { m.year = Int(date.prefix(4)) }
        }
        m.source = (fields["journal"] ?? fields["journaltitle"] ?? fields["booktitle"] ?? fields["school"]
            ?? fields["institution"] ?? fields["howpublished"]).map(clean)
        m.volume = fields["volume"].map(clean)
        m.issue = (fields["number"] ?? fields["issue"]).map(clean)
        m.pages = fields["pages"].map { clean($0.replacingOccurrences(of: "--", with: "-")) }
        m.publisher = (fields["publisher"] ?? fields["organization"]).map(clean)
        m.doi = fields["doi"].map { clean($0).lowercased().replacingOccurrences(of: "https://doi.org/", with: "") }
        m.url = fields["url"].map(clean)
        m.isbn = fields["isbn"].map(clean)
        m.abstract = fields["abstract"].map(clean)
        if let eprint = fields["eprint"].map(clean), (fields["archiveprefix"] ?? fields["eprinttype"]).map(clean)?.lowercased() == "arxiv" {
            m.arxivId = eprint
            if m.type == .journalArticle && m.source == nil { m.type = .preprint; m.source = "arXiv" }
        }
        let keywords = fields["keywords"].map { clean($0).split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } ?? []
        return ReferenceRecord(metadata: m, citationKey: key.isEmpty ? nil : key, keywords: keywords)
    }

    private static func itemType(_ kind: String, fields: [String: String]) -> ItemType {
        switch kind {
        case "article": .journalArticle
        case "inproceedings", "conference", "proceedings": .conferencePaper
        case "book": .book
        case "incollection", "inbook": .bookChapter
        case "phdthesis", "mastersthesis", "thesis": .thesis
        case "techreport", "report": .report
        case "online", "electronic": .webpage
        case "dataset": .dataset
        case "unpublished", "misc":
            (fields["archiveprefix"].map { $0.lowercased().contains("arxiv") } ?? false) ? .preprint : .other
        default: .other
        }
    }

    /// `name = {value}`, `name = "value"`, `name = 2024`, joined with `#` concatenations.
    static func parseFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
            var j = i
            while j < chars.count, chars[j] != "=" { j += 1 }
            guard j < chars.count else { break }
            let name = String(chars[i..<j]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            j += 1
            var value = ""
            while j < chars.count {
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                guard j < chars.count else { break }
                if chars[j] == "{" {
                    var depth = 0, k = j
                    repeat {
                        if chars[k] == "{" { depth += 1 } else if chars[k] == "}" { depth -= 1 }
                        k += 1
                    } while k < chars.count && depth > 0
                    value += String(chars[(j + 1)..<(k - 1)])
                    j = k
                } else if chars[j] == "\"" {
                    var k = j + 1, depth = 0
                    while k < chars.count, !(chars[k] == "\"" && depth == 0) {
                        if chars[k] == "{" { depth += 1 } else if chars[k] == "}" { depth -= 1 }
                        k += 1
                    }
                    value += String(chars[(j + 1)..<min(k, chars.count)])
                    j = k + 1
                } else {
                    var k = j
                    while k < chars.count, chars[k] != ",", chars[k] != "#", !chars[k].isNewline { k += 1 }
                    value += String(chars[j..<k]).trimmingCharacters(in: .whitespaces)
                    j = k
                }
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "#" { j += 1; continue }
                break
            }
            if !name.isEmpty { fields[name] = value }
            i = j
        }
        return fields
    }

    static func authors(_ field: String) -> [Author] {
        clean(field).components(separatedBy: " and ").compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.lowercased() != "others" else { return nil }
            if let comma = name.firstIndex(of: ",") {
                return Author(family: name[..<comma].trimmingCharacters(in: .whitespaces),
                              given: name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces))
            }
            let parts = name.split(separator: " ")
            guard parts.count > 1 else { return Author(family: name) }
            // CJK names written without separators stay whole.
            return Author(family: String(parts.last!), given: parts.dropLast().joined(separator: " "))
        }
    }

    /// Strips braces and turns common LaTeX accents and escapes into Unicode.
    static func clean(_ value: String) -> String {
        var text = value
        let accents: [(String, String)] = [
            ("\\\"a", "ä"), ("\\\"o", "ö"), ("\\\"u", "ü"), ("\\\"A", "Ä"), ("\\\"O", "Ö"), ("\\\"U", "Ü"),
            ("\\'e", "é"), ("\\'a", "á"), ("\\'i", "í"), ("\\'o", "ó"), ("\\'u", "ú"), ("\\'E", "É"), ("\\'c", "ć"),
            ("\\`e", "è"), ("\\`a", "à"), ("\\^e", "ê"), ("\\^o", "ô"), ("\\~n", "ñ"), ("\\c c", "ç"), ("\\c{c}", "ç"),
            ("\\ss", "ß"), ("\\o", "ø"), ("\\aa", "å"), ("\\&", "&"), ("\\%", "%"), ("\\_", "_"), ("\\$", "$"),
            ("\\textendash", "–"), ("\\textemdash", "—"), ("--", "–"), ("~", " "),
        ]
        for (from, to) in accents {
            text = text.replacingOccurrences(of: from, with: to)
            // Braced variants: {\"u} and \"{u}
            if from.count == 3 {
                let command = String(from.prefix(2)), letter = String(from.last!)
                text = text.replacingOccurrences(of: "{\(command)\(letter)}", with: to)
                text = text.replacingOccurrences(of: "\(command){\(letter)}", with: to)
            }
        }
        text = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - RIS

enum RISReader {
    static func parse(_ text: String) -> [ReferenceRecord] {
        var records: [ReferenceRecord] = []
        var tags: [(String, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard line.count >= 5, line.dropFirst(2).hasPrefix("  -") else { continue }
            let tag = String(line.prefix(2))
            let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if tag == "ER" {
                if let record = record(tags) { records.append(record) }
                tags = []
            } else {
                tags.append((tag, value))
            }
        }
        if !tags.isEmpty, let record = record(tags) { records.append(record) }
        return records
    }

    private static func record(_ tags: [(String, String)]) -> ReferenceRecord? {
        func first(_ names: String...) -> String? {
            for name in names { if let v = tags.first(where: { $0.0 == name })?.1, !v.isEmpty { return v } }
            return nil
        }
        guard let title = first("TI", "T1", "CT", "BT") else { return nil }
        var m = Metadata(title: title)
        m.type = switch first("TY") ?? "" {
        case "JOUR", "JFULL", "MGZN": .journalArticle
        case "CONF", "CPAPER": .conferencePaper
        case "BOOK", "EBOOK": .book
        case "CHAP", "ECHAP": .bookChapter
        case "THES": .thesis
        case "RPRT": .report
        case "ELEC", "WEB": .webpage
        case "DATA": .dataset
        case "UNPB", "PREPRINT": .preprint
        default: .other
        }
        m.authors = tags.filter { ["AU", "A1", "A2"].contains($0.0) }.prefix(200).map { BibTeXReader.authors($0.1) }.flatMap { $0 }
        let date = first("PY", "Y1", "DA")
        m.year = date.flatMap { Int($0.prefix(4)) }
        m.source = first("T2", "JO", "JF", "JA", "T3")
        m.volume = first("VL")
        m.issue = first("IS")
        if let start = first("SP") {
            m.pages = first("EP").map { "\(start)-\($0)" } ?? start
        }
        m.publisher = first("PB")
        m.doi = first("DO")?.lowercased().replacingOccurrences(of: "https://doi.org/", with: "")
        m.url = first("UR")
        m.isbn = first("SN")
        m.abstract = first("AB", "N2")
        let keywords = tags.filter { $0.0 == "KW" }.map(\.1)
        return ReferenceRecord(metadata: m, citationKey: first("ID"), keywords: keywords)
    }
}

enum RISWriter {
    static func document(_ entries: [CitationEntry]) -> String {
        entries.map(entry).joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }

    static func entry(_ e: CitationEntry) -> String {
        let m = e.metadata
        var lines: [String] = []
        func add(_ tag: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append("\(tag)  - \(value.replacingOccurrences(of: "\n", with: " "))")
        }
        let kind = switch m.type {
        case .journalArticle: "JOUR"
        case .conferencePaper: "CPAPER"
        case .preprint: "UNPB"
        case .book: "BOOK"
        case .bookChapter: "CHAP"
        case .thesis: "THES"
        case .report: "RPRT"
        case .webpage: "ELEC"
        case .dataset: "DATA"
        case .other: "GEN"
        }
        add("TY", kind)
        add("ID", e.citationKey)
        add("TI", m.title)
        for author in m.authors { add("AU", author.given.isEmpty ? author.family : "\(author.family), \(author.given)") }
        add("PY", m.year.map(String.init))
        add("DA", m.date)
        add("T2", m.source)
        add("VL", m.volume)
        add("IS", m.issue)
        if let pages = m.pages {
            let parts = pages.split(separator: "-", maxSplits: 1).map(String.init)
            add("SP", parts.first)
            if parts.count > 1 { add("EP", parts[1]) }
        }
        add("PB", m.publisher)
        add("DO", m.doi)
        add("UR", m.url)
        add("SN", m.isbn)
        add("AB", m.abstract)
        lines.append("ER  - ")
        return lines.joined(separator: "\n")
    }
}

// MARK: - CSL JSON

enum CSLJSONWriter {
    static func document(_ entries: [CitationEntry]) -> String {
        let items = entries.map { CSLJSONMapper.csljson(id: $0.citationKey, metadata: $0.metadata) }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text + "\n"
    }
}

enum CSLJSONReader {
    static func parse(_ text: String) -> [ReferenceRecord] {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let items = (object as? [[String: Any]]) ?? ((object as? [String: Any]).map { [$0] } ?? [])
        return items.compactMap { item in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            var m = Metadata(title: title)
            m.type = switch item["type"] as? String ?? "" {
            case "article-journal": .journalArticle
            case "paper-conference": .conferencePaper
            case "article": .preprint
            case "book": .book
            case "chapter": .bookChapter
            case "thesis": .thesis
            case "report": .report
            case "webpage": .webpage
            case "dataset": .dataset
            default: .other
            }
            m.authors = (item["author"] as? [[String: Any]] ?? []).compactMap { name in
                if let literal = name["literal"] as? String { return Author(family: literal) }
                guard let family = name["family"] as? String else { return nil }
                return Author(family: family, given: name["given"] as? String ?? "")
            }
            if let parts = (item["issued"] as? [String: Any])?["date-parts"] as? [[Any]], let first = parts.first {
                let numbers = first.compactMap { ($0 as? Int) ?? Int("\($0)") }
                m.year = numbers.first
                if numbers.count > 1 { m.date = numbers.map { String(format: "%02d", $0) }.joined(separator: "-") }
            }
            m.source = item["container-title"] as? String
            m.volume = item["volume"].map { "\($0)" }
            m.issue = item["issue"].map { "\($0)" }
            m.pages = item["page"] as? String
            m.publisher = item["publisher"] as? String
            m.doi = (item["DOI"] as? String)?.lowercased()
            m.url = item["URL"] as? String
            m.abstract = item["abstract"] as? String
            return ReferenceRecord(metadata: m, citationKey: item["id"] as? String, keywords: [])
        }
    }
}
