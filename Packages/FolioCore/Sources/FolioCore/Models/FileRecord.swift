import Foundation
import GRDB

public enum FulltextState: Int, Codable, Sendable {
    case pending = 0, indexed = 1, notApplicable = 2
}

/// A file stored inside the library's `Files/` folder and attached to an item.
public struct FileRecord: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "file"

    public var id: String
    public var itemId: String
    /// Path relative to the library root, e.g. "Files/Zhang_2026_Title.pdf".
    public var relativePath: String
    /// Name of the file when it was imported.
    public var originalName: String
    public var size: Int64
    public var sha256: String
    /// Hash at import time; kept so re-importing the original is still detected after annotation edits.
    public var originalSha256: String
    public var modifiedAt: Date
    public var dateAdded: Date
    public var fulltextState: FulltextState

    public init(id: String = UUID().uuidString, itemId: String, relativePath: String, originalName: String,
                size: Int64, sha256: String, modifiedAt: Date, dateAdded: Date = Date(),
                fulltextState: FulltextState = .pending) {
        self.id = id
        self.itemId = itemId
        self.relativePath = relativePath
        self.originalName = originalName
        self.size = size
        self.sha256 = sha256
        self.originalSha256 = sha256
        self.modifiedAt = modifiedAt
        self.dateAdded = dateAdded
        self.fulltextState = fulltextState
    }

    public var fileName: String { (relativePath as NSString).lastPathComponent }
    public var isPDF: Bool { (relativePath as NSString).pathExtension.lowercased() == "pdf" }
}
