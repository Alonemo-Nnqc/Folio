import AppKit
import FolioCitation
import FolioCore
import FolioMetadata
import Foundation
import PDFKit

/// A tool failure explained for the AI (and, through it, the user).
public struct ToolError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Runs the tools of `ToolCatalog` against one library (AI-01). Every write is followed by a
/// cross-process signal so a running Folio refreshes immediately.
public actor LibraryToolbox {
    public let configuration: AgentConfiguration
    let library: Library
    private let engine: MetadataEngine
    private var renderer: CSLRenderer?

    public init(configuration: AgentConfiguration) throws {
        self.configuration = configuration
        library = try Library(root: configuration.libraryRoot)
        var engineConfiguration = MetadataEngineConfiguration()
        engineConfiguration.mailto = configuration.crossrefMailto
        engineConfiguration.openAlexAPIKey = configuration.openAlexAPIKey
        engineConfiguration.useZoteroRecognizer = configuration.useZoteroRecognizer
        engine = MetadataEngine(configuration: engineConfiguration)
    }

    /// Test seam: an existing library (e.g. `Library.temporary()`).
    init(library: Library, configuration: AgentConfiguration) {
        self.configuration = configuration
        self.library = library
        engine = MetadataEngine(configuration: MetadataEngineConfiguration())
    }

    public var tools: [ToolDefinition] { ToolCatalog.available(allowWrites: configuration.allowWrites) }

    public func call(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        guard let tool = ToolCatalog.tool(named: name) else { throw ToolError("Unknown tool \(name).") }
        if tool.writes && !configuration.allowWrites {
            throw ToolError("The user has turned off changes by AI (Folio ▸ 设置 ▸ AI ▸ 允许 AI 修改文献库). Only reading tools are available.")
        }
        let args = arguments
        let result: JSONValue = switch name {
        case "search_library": try await search(args)
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
        case "import_references": try importReferences(args)
        case "update_item": try updateItem(args)
        case "set_tags": try setTags(args)
        case "set_groups": try setGroups(args)
        case "create_group": try createGroup(args)
        case "move_to_trash": try trash(args)
        case "restore_from_trash": try restore(args)
        case "set_note": try setNote(args)
        default: throw ToolError("Unknown tool \(name).")
        }
        if tool.writes { LibraryChangeSignal.post(root: library.root) }
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
        let candidates = s.items.values.sorted { !$0.isTrashed && $1.isTrashed }
        if let item = candidates.first(where: { $0.doi == doi }) ?? candidates.first(where: { $0.citationKey == raw })
            ?? candidates.first(where: { $0.arxivId != nil && $0.arxivId == raw.replacingOccurrences(of: "arXiv:", with: "") }) {
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

    // MARK: Item JSON

    private func summary(_ item: Item, in s: LibrarySnapshot, matched: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(item.id),
            "title": .string(item.title),
            "authors": .array(item.authors.prefix(8).map { .string(AuthorFormatter.full($0)) }),
            "year": .from(item.year),
            "venue": .from(item.source),
            "type": .string(item.kind == .standalone ? "standalone file (no metadata yet)" : item.type.rawValue),
            "doi": .from(item.doi),
            "citation_key": .from(item.citationKey),
            "tags": .array(s.tags(of: item.id).map { .string($0.name) }),
            "groups": .array(groupNames(of: item.id, in: s).map(JSONValue.string)),
            "has_pdf": .bool(s.files(of: item.id).contains(where: \.isPDF)),
            "read_status": .string(["unread", "reading", "read"][item.readStatus.rawValue]),
        ]
        if item.authors.count > 8 { object["more_authors"] = .number(Double(item.authors.count - 8)) }
        if item.rating > 0 { object["rating"] = .number(Double(item.rating)) }
        if item.isTrashed { object["in_trash"] = true }
        if let arxiv = item.arxivId { object["arxiv"] = .string(arxiv) }
        if let matched { object["matched"] = .number(Double(matched)) }
        return .object(object)
    }

    private func groupNames(of itemId: String, in s: LibrarySnapshot) -> [String] {
        (s.itemGroups[itemId] ?? []).compactMap { id in
            guard let group = s.groupsById[id] else { return nil }
            return group.parentId.flatMap { s.groupsById[$0]?.name }.map { "\($0)/\(group.name)" } ?? group.name
        }.sorted()
    }

    private func detail(_ item: Item, in s: LibrarySnapshot) throws -> JSONValue {
        guard case .object(var object) = summary(item, in: s) else { return .null }
        object["authors"] = .array(item.authors.map { .string(AuthorFormatter.full($0)) })
        object.removeValue(forKey: "more_authors")
        for (key, value) in [("date", item.date), ("volume", item.volume), ("issue", item.issue), ("pages", item.pages),
                             ("publisher", item.publisher), ("isbn", item.isbn), ("url", item.url), ("abstract", item.abstract)] {
            if let value, !value.isEmpty { object[key] = .string(value) }
        }
        object["date_added"] = .string(ISO8601DateFormatter().string(from: item.dateAdded))
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

    /// Ranks by how many query words an item matches (title words count most), so loosely
    /// remembered descriptions still find the paper.
    private func search(_ args: JSONValue) async throws -> JSONValue {
        let query = args["query"]?.stringValue ?? ""
        let tokens = SearchMatcher.tokens(query)
        guard !tokens.isEmpty else { throw ToolError("Empty query.") }
        let s = try snapshot()
        let scope = try scope(args["collection"]?.stringValue, in: s)
        let members = Set(ViewResolver.members(of: scope, in: s, includeSubgroupItems: true))
        let limit = min(max(args["limit"]?.intValue ?? 20, 1), 100)
        var fulltextHits: [String: Int] = [:]
        if args["include_fulltext"]?.boolValue == true {
            for token in tokens {
                for id in (try? library.fulltextItemIds(matching: token)) ?? [] { fulltextHits[id, default: 0] += 1 }
            }
        }
        var scored: [(item: Item, matched: Int, score: Double)] = []
        for id in members {
            guard let item = s.items[id] else { continue }
            let haystack = s.searchText[id] ?? ""
            let title = item.title.lowercased()
            var matched = 0, score = 0.0
            for token in tokens {
                if title.contains(token) { matched += 1; score += 3 }
                else if haystack.contains(token) { matched += 1; score += 1 }
                else if fulltextHits[id] != nil { matched += 1; score += 0.5 }
            }
            score += Double(fulltextHits[id] ?? 0) * 0.25
            if matched > 0 { scored.append((item, matched, score)) }
        }
        scored.sort { ($0.matched, $0.score, $0.item.dateAdded) > ($1.matched, $1.score, $1.item.dateAdded) }
        return [
            "query": .string(query),
            "total_matches": .number(Double(scored.count)),
            "words": .number(Double(tokens.count)),
            "results": .array(scored.prefix(limit).map { summary($0.item, in: s, matched: $0.matched) }),
        ]
    }

    private func listItems(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let scope = try scope(args["collection"]?.stringValue, in: s)
        var ids = ViewResolver.members(of: scope, in: s, includeSubgroupItems: true).compactMap { s.items[$0] }
        switch args["sort"]?.stringValue {
        case "year": ids.sort { ($0.year ?? 0, $0.title) > ($1.year ?? 0, $1.title) }
        case "title": ids.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        default: ids.sort { $0.dateAdded > $1.dateAdded }
        }
        let offset = max(args["offset"]?.intValue ?? 0, 0)
        let limit = min(max(args["limit"]?.intValue ?? 50, 1), 200)
        return [
            "total": .number(Double(ids.count)),
            "offset": .number(Double(offset)),
            "items": .array(ids.dropFirst(offset).prefix(limit).map { summary($0, in: s) }),
        ]
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
            throw ToolError("\"\(item.title)\" has no PDF.")
        }
        return file
    }

    private func readFulltext(_ args: JSONValue) throws -> JSONValue {
        let s = try snapshot()
        let item = try resolveItem(args["item"]?.stringValue, in: s)
        let file = try pdf(of: item, in: s)
        let url = library.fileURL(for: file)
        let maxChars = min(max(args["max_chars"]?.intValue ?? 30_000, 1000), 200_000)
        return try PDFKitSerial.run {
            guard let document = PDFDocument(url: url) else { throw ToolError("Cannot open \(file.fileName).") }
            let count = document.pageCount
            let start = min(max(args["start_page"]?.intValue ?? 1, 1), max(count, 1))
            let end = min(args["end_page"]?.intValue ?? count, count)
            var text = "", last = start - 1, truncated = false
            for index in (start - 1)..<max(end, start - 1) {
                let page = "[Page \(index + 1)]\n" + (document.page(at: index)?.string ?? "") + "\n\n"
                if text.count + page.count > maxChars && !text.isEmpty { truncated = true; break }
                text += page
                last = index + 1
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\[Page \d+\]"#, with: "",
                                                                                         options: .regularExpression).isEmpty {
                return ["title": .string(item.title), "page_count": .from(count), "text": "",
                        "note": "This PDF has no text layer (probably scanned)."]
            }
            var result: [String: JSONValue] = ["title": .string(item.title), "page_count": .from(count),
                                               "pages": .string("\(start)-\(last)"), "text": .string(text)]
            if truncated || last < end { result["next_start_page"] = .from(last + 1) }
            return .object(result)
        }
    }

    private func annotations(_ args: JSONValue) throws -> JSONValue {
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
        let list = entries(try items(args["items"]?.stringList ?? [], in: s))
        guard !list.isEmpty else { throw ToolError("None of these items has bibliographic metadata yet.") }
        let style: CitationStyle = switch args["style"]?.stringValue?.lowercased() {
        case "bibtex": .bibtex
        case "gbt7714", "gb/t 7714", "gbt": .gbt7714
        default: .apa
        }
        if style == .bibtex { return ["style": "bibtex", "text": .string(BibTeXWriter.document(list))] }
        if renderer == nil { renderer = try CSLRenderer() }
        let output = try renderer!.render(list, style: style)
        return ["style": .string(style.rawValue), "text": .string(output.plainText)]
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
            return ["format": .string(format.rawValue), "count": .from(list.count), "path": .string(url.path)]
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
            return ["status": .string(status), "item": try detail(try resolveItem(id, in: try snapshot()), in: try snapshot())]
        case .notFound:
            throw ToolError("Nothing found for \(identifier). Check the identifier.")
        case .networkError:
            throw ToolError("Could not reach the metadata services (network). Try again later.")
        }
    }

    private func addPDF(_ args: JSONValue) async throws -> JSONValue {
        guard let path = args["path"]?.stringValue, !path.isEmpty else { throw ToolError("Missing path.") }
        let url = URL(filePath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("No file at \(url.path).") }
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
                        status = "added without metadata (no match found; it stays a standalone file)"
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

    private func importReferences(_ args: JSONValue) throws -> JSONValue {
        var text = args["text"]?.stringValue ?? ""
        if let path = args["path"]?.stringValue, !path.isEmpty {
            let url = URL(filePath: (path as NSString).expandingTildeInPath)
            guard let data = FileManager.default.contents(atPath: url.path) else { throw ToolError("Cannot read \(url.path).") }
            text = String(decoding: data, as: UTF8.self)
        }
        let records = ReferenceReader.parse(text)
        guard !records.isEmpty else { throw ToolError("No BibTeX, RIS or CSL JSON references found.") }
        let groupId = try args["group"]?.stringValue.map { try ensureGroup($0) }
        let result = try library.importReferences(records.map { ($0.metadata, $0.citationKey) }, toGroup: groupId)
        let s = try snapshot()
        return [
            "parsed": .from(records.count),
            "created": .from(result.created.count),
            "already_in_library": .from(result.duplicates.count),
            "items": .array((result.created + result.duplicates).compactMap { s.items[$0] }.map { summary($0, in: s) }),
        ]
    }

    private func updateItem(_ args: JSONValue) throws -> JSONValue {
        let item = try resolveItem(args["item"]?.stringValue, in: try snapshot())
        var problems: [String] = []
        try library.updateItem(item.id) { item in
            func text(_ key: String) -> String?? {
                guard let value = args[key] else { return nil }
                let string = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                return .some(string?.isEmpty == false ? string : nil)
            }
            if let title = text("title") { if let title { item.title = title } else { problems.append("title cannot be empty") } }
            if let authors = args["authors"]?.arrayValue {
                item.authors = authors.compactMap(\.stringValue).map { name in
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
            if let value = text("doi") { item.doi = value }
            if let value = text("url") { item.url = value }
            if let value = text("abstract") { item.abstract = value }
            if let value = text("citation_key") { item.citationKey = value }
            if let type = args["type"]?.stringValue {
                if let parsed = ItemType(rawValue: type) { item.type = parsed } else { problems.append("unknown type \(type)") }
            }
            if let status = args["read_status"]?.stringValue {
                switch status { case "unread": item.readStatus = .unread; case "reading": item.readStatus = .reading
                case "read": item.readStatus = .read; default: problems.append("unknown read_status \(status)") }
            }
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
        return ["items": .array(ids.compactMap { after.items[$0] }.map { summary($0, in: after) })]
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
        return ["items": .array(ids.compactMap { after.items[$0] }.map { summary($0, in: after) })]
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
