import Foundation
import FolioCore

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

    /// True when `name` looks like a bilingual translation-plugin PDF (`*.compare.pdf`) —
    /// these are ordinary attachments, just not the preferred default file.
    static func isComparePDF(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".compare.pdf")
    }

    /// Orders an item's kept files so the original (non-`.compare.pdf`) file comes first when
    /// both exist; otherwise the earliest by `dateAdded`. The first file is the default.
    static func order(_ files: [PreparedFile]) -> [PreparedFile] {
        files.enumerated()
            .sorted { a, b in
                let ac = isComparePDF(a.element.originalName)
                let bc = isComparePDF(b.element.originalName)
                if ac != bc { return !ac }
                if a.element.dateAdded != b.element.dateAdded { return a.element.dateAdded < b.element.dateAdded }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
