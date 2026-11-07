import AppKit
import FolioCore

extension NSPasteboard.PasteboardType {
    /// One dragged top-level row: `DraggedItem` as JSON.
    static let folioItem = NSPasteboard.PasteboardType("com.nnqc.folio.item")
    /// A dragged sidebar group id.
    static let folioGroup = NSPasteboard.PasteboardType("com.nnqc.folio.group")
}

struct DraggedItem: Codable {
    var itemId: String
    var scopeKey: String
}

extension ViewScope {
    init?(key: String) {
        switch key {
        case "all": self = .all
        case "unfiled": self = .unfiled
        case "trash": self = .trash
        default:
            if key.hasPrefix("group:") { self = .group(String(key.dropFirst(6))) }
            else if key.hasPrefix("tag:") { self = .tag(String(key.dropFirst(4))) }
            else { return nil }
        }
    }
}

enum ItemPasteboard {
    /// A pasteboard item for a dragged row: our private type plus the file URL for Finder/other apps (DND-06).
    static func writer(itemId: String, scope: ViewScope, fileURL: URL?) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(DraggedItem(itemId: itemId, scopeKey: scope.key)),
           let json = String(data: data, encoding: .utf8) {
            item.setString(json, forType: .folioItem)
        }
        if let fileURL { item.setString(fileURL.absoluteString, forType: .fileURL) }
        return item
    }

    static func draggedItems(_ pasteboard: NSPasteboard) -> [DraggedItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            guard let json = item.string(forType: .folioItem), let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(DraggedItem.self, from: data)
        }
    }

    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
