import Foundation
import GRDB

/// Where the reader left a file (READER-06). Stored apart from the library snapshot so that
/// scrolling never triggers a list refresh.
public struct ReadingState: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "readingState"

    public var fileId: String
    public var pageIndex: Int
    /// Top-left of the visible area, in page coordinates.
    public var pointX: Double
    public var pointY: Double
    public var scale: Double
    public var autoScale: Bool
    /// Raw value of `PDFDisplayMode`.
    public var displayMode: Int
    public var dateModified: Date

    public init(fileId: String, pageIndex: Int, pointX: Double, pointY: Double, scale: Double, autoScale: Bool,
                displayMode: Int, dateModified: Date = Date()) {
        self.fileId = fileId
        self.pageIndex = pageIndex
        self.pointX = pointX
        self.pointY = pointY
        self.scale = scale
        self.autoScale = autoScale
        self.displayMode = displayMode
        self.dateModified = dateModified
    }
}

/// An item's Markdown note (NOTE-01).
public struct Note: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "note"

    public var itemId: String
    public var content: String
    public var dateModified: Date

    public init(itemId: String, content: String, dateModified: Date = Date()) {
        self.itemId = itemId
        self.content = content
        self.dateModified = dateModified
    }
}
