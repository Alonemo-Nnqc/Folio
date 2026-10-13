import AppKit
import FolioCitation
import FolioCore
import FolioMetadata
import Foundation
import PDFKit

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A tool failure explained for the AI (and, through it, the user).
public struct ToolError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Runs the tools of `ToolCatalog` against one library (AI-01). Every write is followed by a
/// cross-process signal so a running Folio refreshes immediately.
public actor LibraryToolbox {
    public private(set) var configuration: AgentConfiguration
    /// Re-read before each MCP request so the server follows 设置 ▸ AI and the library location.
    private let configurationSource: (@Sendable () -> AgentConfiguration)?
    private var openedLibrary: Library?
    private let engine: MetadataEngine
    private var renderer: CSLRenderer?

    /// For one-shot commands: opens the library now and fails when it cannot be opened.
    public init(configuration: AgentConfiguration) throws {
        self.configuration = configuration
        configurationSource = nil
        engine = MetadataEngine(configuration: Self.engineConfiguration(configuration))
        openedLibrary = try Self.open(configuration.libraryRoot)
    }

    /// For the MCP server: follows Folio's preferences and opens the library on first use, so the
    /// server always starts and a missing library is explained on each call instead.
    public init(configurationSource: @escaping @Sendable () -> AgentConfiguration) {
        let configuration = configurationSource()
        self.configuration = configuration
        self.configurationSource = configurationSource
        engine = MetadataEngine(configuration: Self.engineConfiguration(configuration))
    }

    /// Test seam: an existing library (e.g. `Library.temporary()`).
    init(library: Library, configuration: AgentConfiguration) {
        self.configuration = configuration
        configurationSource = nil
        openedLibrary = library
        engine = MetadataEngine(configuration: MetadataEngineConfiguration())
    }

    private static func engineConfiguration(_ configuration: AgentConfiguration) -> MetadataEngineConfiguration {
        var engineConfiguration = MetadataEngineConfiguration()
        engineConfiguration.mailto = configuration.crossrefMailto
        engineConfiguration.openAlexAPIKey = configuration.openAlexAPIKey
        engineConfiguration.useZoteroRecognizer = configuration.useZoteroRecognizer
        return engineConfiguration
    }

    /// Re-reads the configuration (cheap: preferences only). A moved library is reopened on next use.
    public func refresh() {
        guard let configurationSource else { return }
        let fresh = configurationSource()
        if fresh.libraryRoot.standardizedFileURL != configuration.libraryRoot.standardizedFileURL {
            openedLibrary = nil
        }
        configuration = fresh
    }

    static func open(_ root: URL) throws -> Library {
        guard FileManager.default.fileExists(atPath: root.appending(path: Library.databaseFileName).path) else {
            throw ToolError("No Folio library at \(root.path). Open Folio once to create it, or check the library location in Folio ▸ 设置 ▸ 文献库.")
        }
        do {
            return try Library(root: root)
        } catch {
            throw ToolError("Cannot open the Folio library at \(root.path): \(error.localizedDescription)")
        }
    }

    var library: Library {
        get throws {
            if let openedLibrary { return openedLibrary }
            let opened = try Self.open(configuration.libraryRoot)
            openedLibrary = opened
            return opened
        }
    }

    public var tools: [ToolDefinition] { ToolCatalog.available(allowWrites: configuration.allowWrites) }

    public func call(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        guard let tool = ToolCatalog.tool(named: name) else { throw ToolError("Unknown tool \(name).") }
        if tool.writes && !configuration.allowWrites {
            throw ToolError("The user has turned off changes by AI (Folio ▸ 设置 ▸ AI ▸ 允许 AI 修改文献库). Only reading tools are available.")
        }
        let args = try tool.validated(arguments)
        let result: JSONValue = switch name {
        case "search_library": try search(args)
        case "list_items": try listItems(args)
        case "list_collections": try listCollections()
        case "get_item": try getItem(args)
        case "read_fulltext": try readFulltext(args)
        case "get_annotations": try annotations(args)
        case "get_note": try note(args)
        case "format_citations": try formatCitations(args)
        case "export_references": try exportReferences(args)
        case "open_in_folio": try openInFolio(args)
        case "add_item_by_identifier": try await addByIdentifier(args)
        case "add_pdf": try await addPDF(args)
        case "attach_file": try await attachFile(args)
        case "import_references": try importReferences(args)
        case "update_item": try updateItem(args)
        case "set_tags": try setTags(args)
        case "set_groups": try setGroups(args)
        case "create_group": try createGroup(args)
        case "create_tag": try createTag(args)
        case "update_tag": try updateTag(args)
        case "delete_tag": try deleteTag(args)
        case "update_group": try updateGroup(args)
        case "delete_group": try deleteGroup(args)
        case "move_to_trash": try trash(args)
        case "restore_from_trash": try restore(args)
        case "set_note": try setNote(args)
        default: throw ToolError("Unknown tool \(name).")
        }
        if tool.writes { LibraryChangeSignal.post(root: try library.root) }
        return result
    }

    // MARK: Lookups

    private func snapshot() throws -> LibrarySnapshot { try library.snapshot() }

    /// An item by id, DOI, citation key or arXiv ID.
    func resolveItem(_ reference: String?, in s: LibrarySnapshot) throws -> Item {
        guard let raw = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw ToolError("Missing item reference.")
        }
        if let item = s.items[raw] { return item }
        let doi = raw.lowercased().replacingOccurrences(of: "https://doi.org/", with: "").replacingOccurrences(of: "doi:", with: "")
        let arxiv = raw.replacingOccurrences(of: "arXiv:", with: "", options: .caseInsensitive)
        let candidates = s.items.values.sorted { !$0.isTrashed && $1.isTrashed }
        if let item = candidates.first(where: { $0.doi == doi }) ?? candidates.first(where: { $0.citationKey == raw })
            ?? candidates.first(where: { $0.arxivId != nil && $0.arxivId == arxiv }) {
            return item
        }
        throw ToolError("No item matches \"\(raw)\". Use search_library to find the item's id.")
    }

    private func items(_ refs: [String], in s: LibrarySnapshot) throws -> [Item] {
        guard !refs.isEmpty else { throw ToolError("No items given.") }
        return try refs.map { try resolveItem($0, in: s) }
    }

    /// `all`, `unfiled`, `trash`, `group:<name|id|Parent/Child>`, `tag:<name|id>`.
    private func scope(_ value: String?, in s: LibrarySnapshot) throws -> ViewScope {
        let text = (value ?? "all").trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "", "all", "library": return .all
        case "unfiled": return .unfiled
        case "trash": return .trash
        default: break
        }
        if text.lowercased().hasPrefix("group:") {
            guard let group = findGroup(String(text.dropFirst(6)), in: s) else { throw ToolError("No group \"\(text.dropFirst(6))\". Use list_collections.") }
            return .group(group.id)
        }
        if text.lowercased().hasPrefix("tag:") {
            guard let tag = findTag(String(text.dropFirst(4)), in: s) else { throw ToolError("No tag \"\(text.dropFirst(4))\". Use list_collections.") }
            return .tag(tag.id)
        }
        if let group = findGroup(text, in: s) { return .group(group.id) }
        if let tag = findTag(text, in: s) { return .tag(tag.id) }
        throw ToolError("Unknown collection \"\(text)\". Use \"all\", \"unfiled\", \"trash\", \"group:<name>\" or \"tag:<name>\".")
    }

    private func findGroup(_ reference: String, in s: LibrarySnapshot) -> LibraryGroup? {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        if let group = s.groupsById[ref] { return group }
        let parts = ref.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 {
            return s.groupsById.values.first { group in
                group.name.caseInsensitiveCompare(parts[1]) == .orderedSame
                    && group.parentId.flatMap { s.groupsById[$0]?.name.caseInsensitiveCompare(parts[0]) == .orderedSame } == true
            }
        }
        let matches = s.groupsById.values.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        return matches.first { $0.parentId == nil } ?? matches.first
    }

    private func findTag(_ reference: String, in s: LibrarySnapshot) -> Tag? {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        return s.tagsById[ref] ?? s.tags.first { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
    }

    // MARK: Filters

    /// The filters shared by search_library and list_items.
    private struct ItemFilter {
        var author: String?
        var yearFrom: Int?
        var yearTo: Int?
        var type: ItemType?
        var status: ReadStatus?
        var tagIds: [String] = []

        var isActive: Bool { author != nil || yearFrom != nil || yearTo != nil || type != nil || status != nil || !tagIds.isEmpty }

        func accepts(_ item: Item, in s: LibrarySnapshot) -> Bool {
            if let author {
                let wanted = author.lowercased()
                guard item.authors.contains(where: { "\($0.given) \($0.family)".lowercased().contains(wanted)
                    || "\($0.family), \($0.given)".lowercased().contains(wanted) }) else { return false }
            }
            if let yearFrom, (item.year ?? Int.min) < yearFrom { return false }
            if let yearTo, (item.year ?? Int.max) > yearTo { return false }
            if let type, item.type != type || item.kind == .standalone { return false }
            if let status, item.readStatus != status { return false }
            if !tagIds.isEmpty {
                let has = Set(s.itemTags[item.id] ?? [])
                guard tagIds.allSatisfy(has.contains) else { return false }
            }
            return true
        }
    }

    private func filter(_ args: JSONValue, in s: LibrarySnapshot) throws -> ItemFilter {
        var filter = ItemFilter()
        filter.author = args["author"]?.stringValue?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        filter.yearFrom = args["year_from"]?.intValue
        filter.yearTo = args["year_to"]?.intValue
        if let type = args["item_type"]?.stringValue?.nilIfEmpty {
            guard let parsed = ItemType(rawValue: type) else {
                throw ToolError("Unknown item_type \"\(type)\". Use one of \(ToolCatalog.itemTypes.joined(separator: ", ")).")
            }
            filter.type = parsed
        }
        if let status = args["read_status"]?.stringValue?.nilIfEmpty {
            filter.status = try Self.readStatus(status)
        }
        filter.tagIds = try (args["tags"]?.stringList ?? []).map { name in
            guard let tag = findTag(name, in: s) else { throw ToolError("No tag \"\(name)\". Use list_collections.") }
            return tag.id
        }
        return filter
    }

    private static func readStatus(_ text: String) throws -> ReadStatus {
        switch text.lowercased() {
        case "unread", "未读": .unread
        case "reading", "在读": .reading
        case "read", "已读": .read
        default: throw ToolError("Unknown read_status \"\(text)\". Use unread, reading or read.")
        }
    }

    /// Members of the collection that pass the filters.
    private func candidates(_ args: JSONValue, in s: LibrarySnapshot) throws -> [Item] {
        let scope = try scope(args["collection"]?.stringValue, in: s)
        let filter = try filter(args, in: s)
        return ViewResolver.members(of: scope, in: s, includeSubgroupItems: true)
            .compactMap { s.items[$0] }.filter { filter.accepts($0, in: s) }
    }

    // MARK: Item JSON

    private func summary(_ item: Item, in s: LibrarySnapshot) -> [String: JSONValue] {
        var object: [String: JSONValue] = [
            "id": .string(item.id),
            "title": .string(item.title),
            "authors": .array(item.authors.prefix(6).map { .string(AuthorFormatter.full($0)) }),
            "year": .from(item.year),
            "venue": .from(item.source),
            "type": .string(item.kind == .standalone ? "standalone file (no metadata yet)" : item.type.rawValue),
            "doi": .from(item.doi),
            "arxiv": .from(item.arxivId),
            "citation_key": .from(item.citationKey),
            "tags": .array(s.tags(of: item.id).map { .string($0.name) }),
            "groups": .array(groupNames(of: item.id, in: s).map(JSONValue.string)),
            "has_pdf": .bool(s.files(of: item.id).contains(where: \.isPDF)),
            "read_status": .string(Self.statusName(item.readStatus)),
        ]
        if item.authors.count > 6 { object["more_authors"] = .number(Double(item.authors.count - 6)) }
        if item.rating > 0 { object["rating"] = .number(Double(item.rating)) }
        if item.isTrashed { object["in_trash"] = true }
        return object
    }

    private static func statusName(_ status: ReadStatus) -> String {
        switch status {
        case .unread: "unread"
        case .reading: "reading"
        case .read: "read"
        }
    }

    private func groupNames(of itemId: String, in s: LibrarySnapshot) -> [String] {
        (s.itemGroups[itemId] ?? []).compactMap { id in
            guard let group = s.groupsById[id] else { return nil }
            return group.parentId.flatMap { s.groupsById[$0]?.name }.map { "\($0)/\(group.name)" } ?? group.name
        }.sorted()
    }

    private func detail(_ item: Item, in s: LibrarySnapshot) throws -> JSONValue {
        let library = try library
        var object = summary(item, in: s)
        object["authors"] = .array(item.authors.map { .string(AuthorFormatter.full($0)) })
        object.removeValue(forKey: "more_authors")
        for (key, value) in [("date", item.date), ("volume", item.volume), ("issue", item.issue), ("pages", item.pages),
                             ("publisher", item.publisher), ("isbn", item.isbn), ("url", item.url), ("abstract", item.abstract)] {
            if let value, !value.isEmpty { object[key] = .string(value) }
        }
        object["date_added"] = .string(ISO8601DateFormatter().string(from: item.dateAdded))
        if let lastRead = try library.lastReadDates()[item.id] {
            object["last_read"] = .string(ISO8601DateFormatter().string(from: lastRead))
        }
        object["files"] = .array(s.files(of: item.id).map { file in
            var entry: [String: JSONValue] = [
                "id": .string(file.id), "name": .string(file.fileName), "path": .string(library.fileURL(for: file).path),
                "is_pdf": .bool(file.isPDF), "is_default": .bool(item.defaultFileId == file.id),
            ]
            if let kind = file.translationKind { entry["translation"] = .string(kind == .mono ? "translated text" : "bilingual") }
            return .object(entry)
        })
        let note = try library.note(for: item.id)
        if !note.isEmpty { object["note"] = .string(note) }
        object["folio_link"] = .string("folio://open?item=\(item.id)")
        return .object(object)
    }

    // MARK: Reading tools

    /// Ranks by how many query words an item matches; words in the title, at the start of a word and
    /// author family names count most, so loosely remembered descriptions still find the paper.
    private func search(_ args: JSONValue) throws -> JSONValue {
        let library = try library
        let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tokens = SearchMatcher.tokens(query)
        let s = try snapshot()
        let pool = try candidates(args, in: s)
        let filtered = try filter(args, in: s).isActive || (args["collection"]?.stringValue?.nilIfEmpty).map { $0 != "all" } == true
        guard !tokens.isEmpty || filtered else {
            throw ToolError("Give a query, or filters (author, year_from, year_to, item_type, read_status, tags, collection).")
        }
        let limit = min(max(args["limit"]?.intValue ?? 20, 1), 200)
        let offset = max(args["offset"]?.intValue ?? 0, 0)
        var perToken: [String: Set<String>] = [:]
        var hits: [String: Library.FulltextHit] = [:]
        if args["include_fulltext"]?.boolValue == true, !tokens.isEmpty {
            for token in tokens { perToken[token] = (try? library.fulltextItemIds(matching: token)) ?? [] }
            for hit in (try? library.fulltextHits(matching: query)) ?? [] { hits[hit.itemId] = hit }
        }
        let phrase = tokens.count > 1 ? tokens.joined(separator: " ") : nil
        var scored: [(item: Item, matched: Int, score: Double)] = []
        for item in pool {
            if tokens.isEmpty { scored.append((item, 0, 0)); continue }
            let haystack = s.searchText[item.id] ?? ""
            let title = item.title.lowercased()
            let families = item.authors.map { $0.family.lowercased() }
            var matched = 0, score = 0.0
            for token in tokens {
                if families.contains(token) { matched += 1; score += 3.5 }
                else if Self.containsWord(token, in: title) { matched += 1; score += 4 }
                else if title.contains(token) { matched += 1; score += 2.5 }
                else if Self.containsWord(token, in: haystack) { matched += 1; score += 1.5 }
                else if haystack.contains(token) { matched += 1; score += 1 }
                else if perToken[token]?.contains(item.id) == true { matched += 1; score += 0.75 }
            }
            if let phrase, title.contains(phrase) { score += 3 }
            if let hit = hits[item.id] { score += min(max(-hit.rank, 0), 20) * 0.05 }
            if matched > 0 { scored.append((item, matched, score)) }
        }
        let sort = args["sort"]?.stringValue?.lowercased() ?? "relevance"
        switch sort {
        case "added": scored.sort { $0.item.dateAdded > $1.item.dateAdded }
        case "year": scored.sort { ($0.item.year ?? 0, $0.matched, $0.score) > ($1.item.year ?? 0, $1.matched, $1.score) }
        case "title": scored.sort { $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending }
        default:
            scored.sort { ($0.matched, $0.score, $0.item.dateAdded) > ($1.matched, $1.score, $1.item.dateAdded) }
        }
        let includeAbstract = args["include_abstract"]?.boolValue == true
        let page = scored.dropFirst(offset).prefix(limit)
        var result: [String: JSONValue] = [
            "total_matches": .from(scored.count),
            "results": .array(page.map { entry in
                var object = summary(entry.item, in: s)
                if !tokens.isEmpty { object["matched"] = .string("\(entry.matched)/\(tokens.count) words") }
                if let hit = hits[entry.item.id], !hit.snippet.isEmpty { object["fulltext_snippet"] = .string(hit.snippet) }
                if includeAbstract, let abstract = entry.item.abstract, !abstract.isEmpty {
                    object["abstract"] = .string(abstract.count > 300 ? String(abstract.prefix(300)) + "…" : abstract)
                }
                return .object(object)
            }),
        ]
        if !query.isEmpty { result["query"] = .string(query) }
        if offset + page.count < scored.count { result["next_offset"] = .from(offset + page.count) }
        if scored.isEmpty {
            result["hint"] = args["include_fulltext"]?.boolValue == true
                ? "Nothing matched. Try fewer or different words (synonyms, an acronym, an author's family name)."
                : "Nothing matched. Try fewer or different words, or include_fulltext: true to search inside the PDFs."
        }
        return .object(result)
    }

    /// Whether `token` occurs at the start of a word in `text` (both lowercased).
    static func containsWord(_ token: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: token, range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: range.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            // CJK text has no spaces: any position is a word start.
            if let scalar = token.unicodeScalars.first, scalar.properties.isIdeographic { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private func listItems(_ args: JSONValue) throws -> JSONValue {
        let library = try library
        let s = try snapshot()
        var items = try candidates(args, in: s)
        switch args["sort"]?.stringValue?.lowercased() {
        case "year": items.sort { ($0.year ?? 0, $0.dateAdded) > ($1.year ?? 0, $1.dateAdded) }
        case "title": items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case "rating": items.sort { ($0.rating, $0.dateAdded) > ($1.rating, $1.dateAdded) }
        case "last_read":
            let dates = try library.lastReadDates()
            items = items.filter { dates[$0.id] != nil }.sorted { dates[$0.id]! > dates[$1.id]! }
        default: items.sort { $0.dateAdded > $1.dateAdded }
        }
        let offset = max(args["offset"]?.intValue ?? 0, 0)
        let limit = min(max(args["limit"]?.intValue ?? 50, 1), 200)
        let page = items.dropFirst(offset).prefix(limit)
        var result: [String: JSONValue] = [
            "total": .from(items.count),
            "items": .array(page.map { .object(summary($0, in: s)) }),
        ]
        if offset + page.count < items.count { result["next_offset"] = .from(offset + page.count) }
        return .object(result)
    }

    private func listCollections() throws -> JSONValue {
        let s = try snapshot()
        let counts = SidebarCounts.compute(s, includeSubgroupItems: true)
        func node(_ id: String) -> JSONValue {
            guard let group = s.groupsById[id] else { return .null }
            var object: [String: JSONValue] = ["id": .string(id), "name": .string(group.name),
                                               "item_count": .from(counts[.group(id)] ?? 0)]
            if let color = group.colorHex { object["color"] = .string(color) }
            let children = s.childGroups[id] ?? []
            if !children.isEmpty { object["subgroups"] = .array(children.map(node)) }
            return .object(object)
        }
        return [
            "all_items": .from(counts[.all] ?? 0),
            "unfiled": .from(counts[.unfiled] ?? 0),
            "trash": .from(counts[.trash] ?? 0),
            "groups": .array(s.topLevelGroups.map(node)),
            "tags": .array(s.tags.map { tag in
                ["id": .string(tag.id), "name": .string(tag.name), "color": .string(tag.colorHex),
                 "item_count": .from(counts[.tag(tag.id)] ?? 0)]
            }),
        ]
    }

    private func getItem(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        return try detail(try resolveItem(args["item"]?.stringValue, in: s), in: s)
    }

    private func pdf(of item: Item, in s: LibrarySnapshot) throws -> FileRecord {
        let files = s.files(of: item.id).filter(\.isPDF)
        guard let file = files.first(where: { $0.id == item.defaultFileId && $0.translationOf == nil })
            ?? files.first(where: { $0.translationOf == nil }) ?? files.first else {
            throw ToolError("\"\(item.title)\" has no PDF. Attach one with attach_file, or add_item_by_identifier with download_pdf.")
        }
        return file
    }

    private func readFulltext(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let item = try resolveItem(args["item"]?.stringValue, in: s)
        let file = try pdf(of: item, in: s)
        let url = try library.fileURL(for: file)
        let maxChars = min(max(args["max_chars"]?.intValue ?? 30_000, 1000), 200_000)
        let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return try PDFKitSerial.run {
            guard let document = PDFDocument(url: url) else { throw ToolError("Cannot open \(file.fileName).") }
            let count = document.pageCount
            guard count > 0 else { throw ToolError("\(file.fileName) has no pages.") }
            let start = min(max(args["start_page"]?.intValue ?? 1, 1), count)
            let end = max(min(args["end_page"]?.intValue ?? count, count), start)
            let pages = (start - 1)..<end
            if !query.isEmpty {
                return Self.passages(in: document, pages: pages, query: query, maxChars: maxChars, title: item.title)
            }
            var text = "", last = start - 1, truncated = false, characters = 0
            for index in pages {
                let page = "[Page \(index + 1)]\n" + (document.page(at: index)?.string ?? "") + "\n\n"
                if characters + page.count > maxChars && !text.isEmpty { truncated = true; break }
                text += page
                characters += page.count
                last = index + 1
            }
            if text.replacingOccurrences(of: #"\[Page \d+\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ["title": .string(item.title), "page_count": .from(count), "pages": .string("\(start)-\(last)"),
                        "note": "These pages have no text layer (probably scanned)."]
            }
            var result: [String: JSONValue] = ["title": .string(item.title), "page_count": .from(count),
                                               "pages": .string("\(start)-\(last)"), "text": .string(text)]
            if truncated || last < end { result["next_start_page"] = .from(last + 1) }
            return .object(result)
        }
    }

    /// The passages of `pages` that mention the query words, with page numbers, best pages first.
    private static func passages(in document: PDFDocument, pages: Range<Int>, query: String, maxChars: Int, title: String) -> JSONValue {
        let tokens = SearchMatcher.tokens(query).filter { $0.count > 1 || $0.unicodeScalars.first?.properties.isIdeographic == true }
        let radius = 280
        var found: [(page: Int, hits: Int, text: String)] = []
        for index in pages {
            guard let raw = document.page(at: index)?.string, !raw.isEmpty else { continue }
            let text = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            let length = text.count
            var windows: [Range<Int>] = []
            var hits = 0
            for token in tokens {
                var from = text.startIndex
                while let range = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                    hits += 1
                    let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                    let matchLength = text.distance(from: range.lowerBound, to: range.upperBound)
                    windows.append(max(0, offset - radius)..<min(length, offset + matchLength + radius))
                    from = range.upperBound
                }
            }
            guard hits > 0 else { continue }
            windows.sort { $0.lowerBound < $1.lowerBound }
            var merged: [Range<Int>] = []
            for window in windows {
                if let last = merged.last, window.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, window.upperBound)
                } else {
                    merged.append(window)
                }
            }
            let excerpt = merged.map { range in
                let from = text.index(text.startIndex, offsetBy: range.lowerBound)
                let to = text.index(text.startIndex, offsetBy: range.upperBound)
                return (range.lowerBound > 0 ? "…" : "") + String(text[from..<to]) + (range.upperBound < length ? "…" : "")
            }.joined(separator: " ")
            found.append((index + 1, hits, excerpt))
        }
        // Pages mentioning the words most often first, then in reading order.
        found.sort { ($0.hits, -$0.page) > ($1.hits, -$1.page) }
        var used = 0
        var kept: [JSONValue] = []
        for entry in found {
            guard used < maxChars else { break }
            let text = entry.text.count + used > maxChars ? String(entry.text.prefix(maxChars - used)) + "…" : entry.text
            used += text.count
            kept.append(["page": .from(entry.page), "mentions": .from(entry.hits), "text": .string(text)])
        }
        var result: [String: JSONValue] = ["title": .string(title), "query": .string(query), "page_count": .from(document.pageCount),
                                           "pages_with_matches": .from(found.count), "passages": .array(kept)]
        if found.isEmpty {
            result["hint"] = "No page mentions these words. Try other words, or read pages without a query."
        }
        return .object(result)
    }

    private func annotations(_ args: JSONValue) throws -> JSONValue {
        let library = try library
        let s = try snapshot()
        let item = try resolveItem(args["item"]?.stringValue, in: s)
        let entries = s.files(of: item.id).filter(\.isPDF).flatMap { file in
            AnnotationReader.annotations(in: library.fileURL(for: file)).map { annotation -> JSONValue in
                var object: [String: JSONValue] = ["kind": .string(annotation.kind.rawValue), "page": .from(annotation.page),
                                                   "color": .string(annotation.colorHex), "file": .string(file.fileName)]
                if !annotation.quotedText.isEmpty { object["text"] = .string(annotation.quotedText) }
                if !annotation.comment.isEmpty { object["comment"] = .string(annotation.comment) }
                return .object(object)
            }
        }
        return ["title": .string(item.title), "count": .from(entries.count), "annotations": .array(entries)]
    }

    private func note(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let item = try resolveItem(args["item"]?.stringValue, in: s)
        return ["title": .string(item.title), "note": .string(try library.note(for: item.id))]
    }

    private func entries(_ items: [Item]) -> [CitationEntry] {
        items.filter { $0.kind == .regular }.map {
            CitationEntry(id: $0.id, citationKey: $0.citationKey ?? CitationKeyGenerator.baseKey(for: $0.metadata), metadata: $0.metadata)
        }
    }

    private func formatCitations(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let chosen = try items(args["items"]?.stringList ?? [], in: s)
        let list = entries(chosen)
        guard !list.isEmpty else { throw ToolError("None of these items has bibliographic metadata yet.") }
        let styleName = args["style"]?.stringValue ?? "apa"
        guard let style = CitationStyle.named(styleName) else {
            throw ToolError("Unknown style \"\(styleName)\". Use one of \(CitationStyle.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let mode = args["mode"]?.stringValue?.lowercased() ?? "bibliography"
        if renderer == nil { renderer = try CSLRenderer() }
        var result: [String: JSONValue] = ["style": .string(style.displayName)]
        if mode == "bibliography" || mode == "both" {
            result["text"] = .string(try renderer!.render(list, style: style).plainText)
        }
        if mode == "in_text" || mode == "both" {
            let citations = try renderer!.inTextCitations(list, style: style)
            result["in_text"] = .array(zip(list, citations.each).map { entry, citation in
                ["item": .string(entry.id), "title": .string(entry.metadata.title), "citation": .string(citation)]
            })
            if list.count > 1 { result["in_text_combined"] = .string(citations.combined) }
        }
        let skipped = chosen.filter { $0.kind != .regular }.map(\.title)
        if !skipped.isEmpty {
            result["skipped"] = .array(skipped.map(JSONValue.string))
            result["note"] = "Skipped items have no bibliographic metadata yet; fix them with update_item or add_item_by_identifier."
        }
        return .object(result)
    }

    private func exportReferences(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let refs = args["items"]?.stringList ?? []
        let chosen: [Item] = refs.isEmpty
            ? ViewResolver.members(of: try scope(args["collection"]?.stringValue, in: s), in: s, includeSubgroupItems: true)
                .compactMap { s.items[$0] }.sorted { $0.dateAdded < $1.dateAdded }
            : try items(refs, in: s)
        let list = entries(chosen)
        guard !list.isEmpty else { throw ToolError("Nothing to export.") }
        let format = ReferenceFormat(rawValue: args["format"]?.stringValue?.lowercased() ?? "bibtex") ?? .bibtex
        let text = format.render(list)
        if let path = args["path"]?.stringValue, !path.isEmpty {
            var url = URL(filePath: (path as NSString).expandingTildeInPath)
            if url.pathExtension.isEmpty { url.appendPathExtension(format.fileExtension) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return ["format": .string(format.rawValue), "count": .from(list.count), "path": .string(url.path),
                    "citation_keys": .array(list.map { .string($0.citationKey) })]
        }
        return ["format": .string(format.rawValue), "count": .from(list.count), "text": .string(text)]
    }

    private func openInFolio(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let item = try resolveItem(args["item"]?.stringValue, in: s)
        var components = URLComponents()
        components.scheme = "folio"
        components.host = args["select_only"]?.boolValue == true ? "select" : "open"
        components.queryItems = [URLQueryItem(name: "item", value: item.id)]
        if let page = args["page"]?.intValue { components.queryItems?.append(URLQueryItem(name: "page", value: String(page))) }
        guard let url = components.url, NSWorkspace.shared.open(url) else { throw ToolError("Could not open Folio.") }
        return ["opened": .string(item.title), "link": .string(url.absoluteString)]
    }

    // MARK: Writing tools

    private func addByIdentifier(_ args: JSONValue) async throws -> JSONValue {
        guard let identifier = args["identifier"]?.stringValue, !identifier.isEmpty else { throw ToolError("Missing identifier.") }
        let library = try library
        switch await engine.resolve(identifier: identifier) {
        case .found(let metadata):
            let groupId = try args["group"]?.stringValue.map { try ensureGroup($0) }
            let id: String, status: String
            switch try library.createItem(metadata, inGroup: groupId) {
            case .created(let created): (id, status) = (created, "created")
            case .duplicate(let existing):
                (id, status) = (existing, "already in library")
                if let groupId { _ = try library.addItems([existing], toGroup: groupId, includeSubgroups: false) }
            }
            try applyTags(args["tags"]?.stringList ?? [], to: [id])
            var result: [String: JSONValue] = ["status": .string(status)]
            if args["download_pdf"]?.boolValue == true {
                result["pdf"] = .string(await downloadOpenAccessPDF(for: id, metadata: metadata))
            }
            let s = try snapshot()
            result["item"] = try detail(try resolveItem(id, in: s), in: s)
            return .object(result)
        case .notFound:
            throw ToolError("Nothing found for \(identifier). Check the identifier.")
        case .networkError:
            throw ToolError("Could not reach the metadata services (network). Try again later.")
        }
    }

    /// Finds, downloads and attaches an open-access PDF; returns what happened, for the result.
    private func downloadOpenAccessPDF(for itemId: String, metadata: Metadata) async -> String {
        if let s = try? snapshot(), s.files(of: itemId).contains(where: \.isPDF) { return "the item already has a PDF" }
        guard let url = await OpenAccessPDF.locate(doi: metadata.doi, arxivId: metadata.arxivId, mailto: configuration.crossrefMailto,
                                                   apiKey: configuration.openAlexAPIKey) else {
            return "no open-access PDF found (attach one with attach_file if the user has it)"
        }
        do {
            let file = try await OpenAccessPDF.download(url, mailto: configuration.crossrefMailto)
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            switch try library.addFiles([file], toItem: itemId, autoRename: configuration.autoRenameFiles).first {
            case .added?: return "attached (\(url.absoluteString))"
            case .duplicate?: return "this PDF is already in the library"
            case .failed(_, let reason)?: return "could not attach: \(reason)"
            case nil: return "could not attach"
            }
        } catch {
            return "\(error.localizedDescription) (\(url.absoluteString))"
        }
    }

    /// A local file, or a URL downloaded into a temporary folder (removed by `cleanup`).
    private func sourceFile(_ args: JSONValue) async throws -> (url: URL, cleanup: () -> Void) {
        if let path = args["path"]?.stringValue?.nilIfEmpty {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("No file at \(url.path).") }
            return (url, {})
        }
        if let link = args["url"]?.stringValue?.nilIfEmpty {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased()) else {
                throw ToolError("\"\(link)\" is not an http(s) URL.")
            }
            let file = try await OpenAccessPDF.download(url, mailto: configuration.crossrefMailto)
            return (file, { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) })
        }
        throw ToolError("Give `path` (a file on disk) or `url` (a PDF to download).")
    }

    private func addPDF(_ args: JSONValue) async throws -> JSONValue {
        let library = try library
        let (url, cleanup) = try await sourceFile(args)
        defer { cleanup() }
        let groupId = try args["group"]?.stringValue.map { try ensureGroup($0) }
        guard let outcome = try library.importFiles([url], toGroup: groupId).first else { throw ToolError("Import failed.") }
        var itemId: String
        var status = "added"
        switch outcome {
        case let .imported(id, isPDF):
            itemId = id
            if isPDF {
                if args["retrieve_metadata"]?.boolValue ?? true {
                    switch await engine.resolve(pdfAt: library.fileURL(for: try library.files(ofItem: id)[0])) {
                    case .found(let metadata):
                        switch try library.applyMetadata(metadata, toStandalone: id, autoRename: configuration.autoRenameFiles) {
                        case .created: status = "added with metadata"
                        case .duplicateItem(let existing):
                            // The work is already there: keep one item and attach this file to it (DUP-03).
                            try library.mergeStandalone(id, intoItem: existing, autoRename: configuration.autoRenameFiles)
                            itemId = existing
                            status = "attached to the existing item for this work"
                        }
                    case .notFound:
                        try library.setMetadataState(.failed, for: id)
                        status = "added without metadata (no match found; it stays a standalone file — fix it with update_item)"
                    case .networkError:
                        try library.setMetadataState(.networkFailed, for: id, incrementRetry: true)
                        status = "added; metadata lookup failed (network) and Folio will retry"
                    }
                } else {
                    try library.setMetadataState(.none, for: id)
                    status = "added without looking up metadata"
                }
            }
        case let .duplicateFile(existing, _):
            itemId = existing
            status = "this exact file is already in the library"
        case let .duplicateInTrash(existing):
            try library.restoreItems([existing])
            itemId = existing
            status = "this file was in the trash and has been restored"
        case let .failed(_, reason):
            throw ToolError("Could not add the file: \(reason)")
        }
        try applyTags(args["tags"]?.stringList ?? [], to: [itemId])
        let s = try snapshot()
        return ["status": .string(status), "item": try detail(try resolveItem(itemId, in: s), in: s)]
    }

    private func attachFile(_ args: JSONValue) async throws -> JSONValue {
        let library = try library
        let item = try resolveItem(args["item"]?.stringValue, in: try snapshot())
        guard !item.isTrashed else { throw ToolError("\"\(item.title)\" is in the trash; restore it first.") }
        let (url, cleanup) = try await sourceFile(args)
        defer { cleanup() }
        let status: String
        switch try library.addFiles([url], toItem: item.id, autoRename: configuration.autoRenameFiles).first {
        case .added(let fileId)?:
            status = "attached"
            if args["make_default"]?.boolValue == true { try library.setDefaultFile(fileId) }
        case .duplicate(let owner)?:
            status = owner == item.id ? "this file is already attached to the item" : "this file already belongs to another item (\(owner))"
        case .failed(_, let reason)?:
            throw ToolError("Could not attach the file: \(reason)")
        case nil:
            throw ToolError("Could not attach the file.")
        }
        let s = try snapshot()
        return ["status": .string(status), "item": try detail(try resolveItem(item.id, in: s), in: s)]
    }

    private func importReferences(_ args: JSONValue) throws -> JSONValue {
        let library = try library
        var text = args["text"]?.stringValue ?? ""
        if let path = args["path"]?.stringValue, !path.isEmpty {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            guard let data = FileManager.default.contents(atPath: url.path) else { throw ToolError("Cannot read \(url.path).") }
            text = String(decoding: data, as: UTF8.self)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError("Give `path` or `text`.") }
        let records = ReferenceReader.parse(text)
        guard !records.isEmpty else { throw ToolError("No BibTeX, RIS or CSL JSON references found.") }
        let groupId = try args["group"]?.stringValue.map { try ensureGroup($0) }
        let result = try library.importReferences(records.map { ($0.metadata, $0.citationKey) }, toGroup: groupId)
        let s = try snapshot()
        return [
            "parsed": .from(records.count),
            "created": .from(result.created.count),
            "already_in_library": .from(result.duplicates.count),
            "items": .array((result.created + result.duplicates).compactMap { s.items[$0] }.map { .object(summary($0, in: s)) }),
        ]
    }

    private func updateItem(_ args: JSONValue) throws -> JSONValue {
        let library = try library
        let item = try resolveItem(args["item"]?.stringValue, in: try snapshot())
        var problems: [String] = []
        let status = try args["read_status"]?.stringValue.map(Self.readStatus)
        try library.updateItem(item.id) { item in
            func text(_ key: String) -> String?? {
                guard let value = args[key] else { return nil }
                let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .some(string?.isEmpty == false ? string : nil)
            }
            if let title = text("title") { if let title { item.title = title } else { problems.append("title cannot be empty") } }
            if let authors = args["authors"]?.stringList, args["authors"] != nil {
                item.authors = authors.map { name in
                    let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return parts.count == 2 ? Author(family: parts[0], given: parts[1]) : Author(family: name)
                }
            }
            if let year = args["year"] { item.year = year.intValue }
            if let value = text("venue") { item.source = value }
            if let value = text("volume") { item.volume = value }
            if let value = text("issue") { item.issue = value }
            if let value = text("pages") { item.pages = value }
            if let value = text("publisher") { item.publisher = value }
            if let value = text("doi") { item.doi = value?.lowercased() }
            if let value = text("url") { item.url = value }
            if let value = text("abstract") { item.abstract = value }
            if let value = text("citation_key") { item.citationKey = value }
            if let type = args["type"]?.stringValue {
                if let parsed = ItemType(rawValue: type) { item.type = parsed } else { problems.append("unknown type \(type)") }
            }
            if let status { item.readStatus = status }
            if let rating = args["rating"]?.intValue { item.rating = min(max(rating, 0), 5) }
            if item.kind == .standalone && args["title"] != nil { item.kind = .regular; item.metadataState = .resolved }
        }
        let s = try snapshot()
        var result: [String: JSONValue] = ["item": try detail(try resolveItem(item.id, in: s), in: s)]
        if !problems.isEmpty { result["warnings"] = .array(problems.map(JSONValue.string)) }
        return .object(result)
    }

    /// Tags by name (case-insensitive); missing ones are created in the palette's next colour.
    private func ensureTag(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespaces)
        let s = try snapshot()
        if let tag = findTag(clean, in: s) { return tag.id }
        let palette = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#32ADE6", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55"]
        return try library.createTag(name: clean, colorHex: palette[s.tags.count % palette.count]).id
    }

    private func applyTags(_ names: [String], to ids: [String]) throws {
        for name in names where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            try library.setTag(try ensureTag(name), onItems: ids, enabled: true)
        }
    }

    /// Groups by name, id or "Parent/Child"; missing ones are created (two levels at most).
    private func ensureGroup(_ reference: String, create: Bool = true) throws -> String {
        let s = try snapshot()
        if let group = findGroup(reference, in: s) { return group.id }
        guard create else { throw ToolError("No group \"\(reference)\".") }
        let parts = reference.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let leaf = parts.last else { throw ToolError("Empty group name.") }
        var parentId: String?
        if parts.count >= 2 {
            parentId = try findGroup(parts[0], in: s)?.id ?? library.createGroup(name: parts[0]).id
        }
        return try library.createGroup(name: leaf, parentId: parentId).id
    }

    private func setTags(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let ids = try items(args["items"]?.stringList ?? [], in: s).map(\.id)
        try applyTags(args["add"]?.stringList ?? [], to: ids)
        for name in args["remove"]?.stringList ?? [] {
            if let tag = findTag(name, in: try snapshot()) { try library.setTag(tag.id, onItems: ids, enabled: false) }
        }
        let after = try snapshot()
        return ["items": .array(ids.compactMap { after.items[$0] }.map { .object(summary($0, in: after)) })]
    }

    private func setGroups(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let ids = try items(args["items"]?.stringList ?? [], in: s).map(\.id)
        let create = args["create_missing"]?.boolValue ?? true
        for name in args["add"]?.stringList ?? [] {
            _ = try library.addItems(ids, toGroup: try ensureGroup(name, create: create), includeSubgroups: false)
        }
        for name in args["remove"]?.stringList ?? [] {
            guard let group = findGroup(name, in: try snapshot()) else { throw ToolError("No group \"\(name)\".") }
            try library.removeItems(ids, fromGroup: group.id, includeSubgroups: true)
        }
        let after = try snapshot()
        return ["items": .array(ids.compactMap { after.items[$0] }.map { .object(summary($0, in: after)) })]
    }

    private func createGroup(_ args: JSONValue) throws -> JSONValue {
        guard let name = args["name"]?.stringValue, !name.isEmpty else { throw ToolError("Missing name.") }
        let s = try snapshot()
        var parentId: String?
        if let parent = args["parent"]?.stringValue, !parent.isEmpty {
            guard let group = findGroup(parent, in: s) else { throw ToolError("No parent group \"\(parent)\".") }
            guard group.parentId == nil else { throw ToolError("Groups are at most two levels deep; \"\(parent)\" is already a subgroup.") }
            parentId = group.id
        }
        do {
            let group = try library.createGroup(name: name, parentId: parentId)
            return ["id": .string(group.id), "name": .string(group.name)]
        } catch LibraryError.duplicateGroupName {
            throw ToolError("A group named \"\(name)\" already exists there.")
        }
    }

    // MARK: Tags and groups

    static let namedColors: [String: String] = [
        "red": "#FF3B30", "orange": "#FF9500", "yellow": "#FFCC00", "green": "#34C759", "mint": "#00C7BE",
        "cyan": "#32ADE6", "teal": "#32ADE6", "blue": "#007AFF", "indigo": "#5856D6", "purple": "#AF52DE",
        "pink": "#FF2D55", "gray": "#8E8E93", "grey": "#8E8E93",
        "红": "#FF3B30", "橙": "#FF9500", "黄": "#FFCC00", "绿": "#34C759", "青": "#32ADE6", "蓝": "#007AFF",
        "靛": "#5856D6", "紫": "#AF52DE", "粉": "#FF2D55", "灰": "#8E8E93",
    ]

    /// A colour name or #RRGGBB → "#RRGGBB".
    static func hexColor(_ value: String?) throws -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let named = namedColors[raw.lowercased()] ?? namedColors[raw] { return named }
        let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else {
            throw ToolError("Unknown colour \"\(raw)\". Use a colour name (red, blue, …) or #RRGGBB.")
        }
        return "#" + hex.uppercased()
    }

    private func tagJSON(_ tag: Tag, in s: LibrarySnapshot) -> JSONValue {
        ["id": .string(tag.id), "name": .string(tag.name), "color": .string(tag.colorHex),
         "item_count": .from(s.tagItems[tag.id]?.count ?? 0)]
    }

    private func requireTag(_ args: JSONValue, in s: LibrarySnapshot) throws -> Tag {
        guard let ref = args["tag"]?.stringValue, let tag = findTag(ref, in: s) else {
            throw ToolError("No tag \"\(args["tag"]?.stringValue ?? "")\". Use list_collections.")
        }
        return tag
    }

    private func createTag(_ args: JSONValue) throws -> JSONValue {
        guard let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw ToolError("Missing name.")
        }
        let s = try snapshot()
        if let existing = findTag(name, in: s) { return ["status": "already exists", "tag": tagJSON(existing, in: s)] }
        let color = try Self.hexColor(args["color"]?.stringValue)
        let id = try ensureTag(name)
        if let color { try library.updateTag(id, name: name, colorHex: color) }
        let after = try snapshot()
        return ["status": "created", "tag": tagJSON(after.tagsById[id]!, in: after)]
    }

    private func updateTag(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let tag = try requireTag(args, in: s)
        let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? tag.name
        let color = try Self.hexColor(args["color"]?.stringValue) ?? tag.colorHex
        do {
            try library.updateTag(tag.id, name: name, colorHex: color)
        } catch LibraryError.duplicateTagName {
            throw ToolError("A tag named \"\(name)\" already exists. Use set_tags to move items to it, then delete_tag the old one.")
        }
        let after = try snapshot()
        return ["tag": tagJSON(after.tagsById[tag.id]!, in: after)]
    }

    private func deleteTag(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let tag = try requireTag(args, in: s)
        let count = s.tagItems[tag.id]?.count ?? 0
        try library.deleteTag(tag.id)
        return ["deleted_tag": .string(tag.name), "removed_from_items": .from(count)]
    }

    private func requireGroup(_ args: JSONValue, in s: LibrarySnapshot) throws -> LibraryGroup {
        guard let ref = args["group"]?.stringValue, let group = findGroup(ref, in: s) else {
            throw ToolError("No group \"\(args["group"]?.stringValue ?? "")\". Use list_collections.")
        }
        return group
    }

    private func updateGroup(_ args: JSONValue) throws -> JSONValue {
        let library = try library
        let s = try snapshot()
        let group = try requireGroup(args, in: s)
        if let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name != group.name {
            do { try library.renameGroup(group.id, to: name) } catch LibraryError.duplicateGroupName {
                throw ToolError("A sibling group named \"\(name)\" already exists.")
            }
        }
        if let color = args["color"]?.stringValue {
            try library.setGroupColor(group.id, colorHex: color.lowercased() == "default" ? nil : try Self.hexColor(color))
        }
        if let parent = args["parent"]?.stringValue {
            let parentId: String? = parent.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try {
                guard let target = findGroup(parent, in: s) else { throw ToolError("No group \"\(parent)\".") }
                return target.id
            }()
            guard try library.canMoveGroup(group.id, toParent: parentId) else {
                throw ToolError("Cannot move \"\(group.name)\" there: groups are at most two levels deep, and a group with subgroups cannot become a subgroup.")
            }
            let siblings = parentId.map { s.childGroups[$0] ?? [] } ?? s.topLevelGroups
            try library.moveGroup(group.id, toParent: parentId, index: siblings.count)
        }
        let after = try snapshot()
        let updated = after.groupsById[group.id]!
        var result: [String: JSONValue] = ["id": .string(updated.id), "name": .string(updated.name),
                                           "parent": .from(updated.parentId.flatMap { after.groupsById[$0]?.name })]
        if let color = updated.colorHex { result["color"] = .string(color) }
        return .object(result)
    }

    private func deleteGroup(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let group = try requireGroup(args, in: s)
        let trashItems = args["trash_items"]?.boolValue ?? false
        let members = ViewResolver.members(of: .group(group.id), in: s, includeSubgroupItems: true)
        try library.deleteGroup(group.id, trashItems: trashItems)
        return ["deleted_group": .string(group.name),
                "subgroups_deleted": .from(s.childGroups[group.id]?.count ?? 0),
                trashItems ? "items_moved_to_trash" : "items_kept_in_library": .from(members.count)]
    }

    private func trash(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let chosen = try items(args["items"]?.stringList ?? [], in: s).filter { !$0.isTrashed }
        try library.trashItems(chosen.map(\.id))
        return ["moved_to_trash": .array(chosen.map { .string($0.title) }),
                "note": "Restorable with restore_from_trash for 30 days."]
    }

    private func restore(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let chosen = try items(args["items"]?.stringList ?? [], in: s).filter(\.isTrashed)
        try library.restoreItems(chosen.map(\.id))
        return ["restored": .array(chosen.map { .string($0.title) })]
    }

    private func setNote(_ args: JSONValue) throws -> JSONValue {
        let library = try library
        let item = try resolveItem(args["item"]?.stringValue, in: try snapshot())
        let content = args["content"]?.stringValue ?? ""
        var note = content
        if args["mode"]?.stringValue != "replace" {
            let current = try library.note(for: item.id)
            note = current.isEmpty ? content : current + (current.hasSuffix("\n") ? "\n" : "\n\n") + content
        }
        try library.setNote(note, for: item.id)
        return ["title": .string(item.title), "note": .string(try library.note(for: item.id))]
    }
}
