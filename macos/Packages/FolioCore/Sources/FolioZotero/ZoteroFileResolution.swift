import Foundation
import FolioCore
import FolioTranslate

/// Zotero's fixed `itemAttachments.linkMode` values (not stored anywhere as a lookup table).
enum ZoteroLinkMode {
    static let importedFile = 0
    /// Downloaded via a URL — this covers both actual web snapshots (`text/html`) *and*
    /// PDFs/other files the browser connector grabbed automatically. Only the HTML ones are
    /// "web snapshots" to skip per ZOT-03; see `ZoteroAttachmentResolver.isHTMLSnapshot`.
    static let importedURL = 1
    static let linkedFile = 2
    /// Linked URL (no local file) — skipped per ZOT-03.
    static let linkedURL = 3
}

enum ZoteroAttachmentResolver {
    /// Resolves an attachment's on-disk location.
    /// - `key` is the attachment item's own key (imported files live under `storage/<key>/`).
    /// - `path` is `itemAttachments.path`: `storage:<name>` for imported files, an absolute
    ///   path or `attachments:<relative path>` for linked files.
    static func resolveURL(dataDirectory: URL, key: String, path: String?, baseAttachmentPath: String?) -> URL {
        guard let path, !path.isEmpty else {
            return dataDirectory.appendingPathComponent("storage").appendingPathComponent(key)
        }
        if path.hasPrefix("storage:") {
            let filename = String(path.dropFirst("storage:".count))
            return dataDirectory.appendingPathComponent("storage").appendingPathComponent(key).appendingPathComponent(filename)
        }
        if path.hasPrefix("attachments:") {
            let relative = String(path.dropFirst("attachments:".count))
            if let base = baseAttachmentPath, !base.isEmpty {
                return URL(fileURLWithPath: base).appendingPathComponent(relative)
            }
            return URL(fileURLWithPath: relative)
        }
        return URL(fileURLWithPath: path)
    }

    /// True when a `linkMode == importedURL` (1) attachment is an actual web snapshot to skip
    /// per ZOT-03: `text/html` content, or (as a fallback, when `contentType` is missing) an
    /// `.html`/`.htm` file name. Any other content — PDFs, EPUBs, etc. the connector downloaded
    /// the same way — is kept exactly like an imported file (linkMode 0).
    static func isHTMLSnapshot(contentType: String?, path: String?) -> Bool {
        if let contentType, !contentType.isEmpty {
            return contentType.lowercased() == "text/html"
        }
        if let path {
            let lower = path.lowercased()
            return lower.hasSuffix(".html") || lower.hasSuffix(".htm")
        }
        return false
    }

    /// What Zotero's pdf2zh plugin made, read from the file name (`Paper.compare.pdf`, `Paper.zh.dual.pdf`,
    /// `Paper-mono.pdf`) and the attachment's title, which names the service (`ConDSeg-google-compare`,
    /// `deepseek-compare`). Several translations of one paper share a file name; only the title tells them apart.
    /// Nil for anything else.
    static func translation(fileName: String, title: String?) -> (kind: TranslationKind, service: String?)? {
        let lower = fileName.lowercased()
        let tokens = (title ?? "").lowercased().split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        let titleMode = tokens.count > 1 ? tokens.last : nil
        let kind: TranslationKind
        if lower.range(of: #"[.-](dual|compare)\.pdf$"#, options: .regularExpression) != nil || ["dual", "compare"].contains(titleMode) {
            kind = .dual
        } else if lower.range(of: #"[.-]mono\.pdf$"#, options: .regularExpression) != nil || titleMode == "mono" {
            kind = .mono
        } else {
            return nil
        }
        // The service is the word before the mode; titles without one ("ConDSeg-compare") name none.
        let service = titleMode != nil && ["dual", "compare", "mono"].contains(titleMode)
            ? TranslationNaming.serviceName(id: pluginServiceIDs[tokens[tokens.count - 2]] ?? tokens[tokens.count - 2]) : nil
        return (kind, service)
    }

    /// The plugin's own names for services Folio calls otherwise.
    private static let pluginServiceIDs = ["openailiked": "openaicompatible"]

    /// Orders an item's kept files so the original (not a translation) comes first when both exist;
    /// otherwise the earliest by `dateAdded`. The first file is the default.
    static func order(_ files: [PreparedFile]) -> [PreparedFile] {
        files.enumerated()
            .sorted { a, b in
                let ac = a.element.translationKind != nil
                let bc = b.element.translationKind != nil
                if ac != bc { return !ac }
                if a.element.dateAdded != b.element.dateAdded { return a.element.dateAdded < b.element.dateAdded }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
