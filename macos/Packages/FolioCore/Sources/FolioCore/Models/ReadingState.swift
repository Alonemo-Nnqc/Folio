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
    /// Pages of the document when it was last read (nil: last read by a version before 1.6).
    public var pageCount: Int?
    /// The pages that were on screen for a moment, as a string of 0 and 1 (nil: not known, the pages before `pageIndex`).
    public var seenPages: String?

    public init(fileId: String, pageIndex: Int, pointX: Double, pointY: Double, scale: Double, autoScale: Bool,
                displayMode: Int, dateModified: Date = Date(), pageCount: Int? = nil, seenPages: String? = nil) {
        self.pageCount = pageCount
        self.seenPages = seenPages
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

/// How far a paper has been read: the page reached, of the file of it that was read furthest (its original or one of its
/// translations), and when any of them was last read.
public struct ReadingProgress: Sendable, Hashable {
    /// The page reached (0-based), of how many, in which file.
    public var pageIndex: Int
    public var pageCount: Int?
    public var fileId: String
    public var lastRead: Date
    /// 0…1.
    public var fraction: Double { pageCount.map { $0 > 0 ? min(Double(pageIndex + 1) / Double($0), 1) : 0 } ?? 0 }

    public init(pageIndex: Int, pageCount: Int?, fileId: String, lastRead: Date) {
        self.fileId = fileId
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.lastRead = lastRead
    }
}

/// The pages of a document that have been on screen.
public struct SeenPages: Sendable, Equatable {
    public private(set) var flags: [Bool]

    /// `saved`: as stored; nil for a file last read before 1.6, whose pages up to `through` count as seen.
    public init(count: Int, saved: String? = nil, through: Int? = nil) {
        flags = Array(repeating: false, count: max(count, 0))
        if let saved {
            for (k, c) in saved.prefix(flags.count).enumerated() where c == "1" { flags[k] = true }
        } else if let through {
            for k in flags.indices where k <= through { flags[k] = true }
        }
    }

    public mutating func insert(_ page: Int) { if flags.indices.contains(page) { flags[page] = true } }

    public var count: Int { flags.lazy.filter { $0 }.count }
    /// The page reached: the last one seen with at least half of the pages up to it seen. Pages skimmed over do not hold it
    /// back; a jump ahead (to the references) does not count as reading up to there.
    public var reached: Int? {
        var seen = 0, result: Int?
        for (page, flag) in flags.enumerated() where flag {
            seen += 1
            if seen * 2 >= page + 1 { result = page }
        }
        return result ?? flags.firstIndex(of: true).map { _ in 0 }
    }
    public var stored: String { String(flags.map { $0 ? "1" : "0" }) }
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
