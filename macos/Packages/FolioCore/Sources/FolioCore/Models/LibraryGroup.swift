import Foundation
import GRDB

/// A user-created group. Groups nest at most two levels deep.
public struct LibraryGroup: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "libraryGroup"

    public var id: String
    public var parentId: String?
    public var name: String
    public var position: Double
    public var dateCreated: Date
    /// Sidebar icon colour ("#RRGGBB"); nil = the accent colour.
    public var colorHex: String?

    public init(id: String = UUID().uuidString, parentId: String? = nil, name: String, position: Double,
                dateCreated: Date = Date()) {
        self.id = id
        self.parentId = parentId
        self.name = name
        self.position = position
        self.dateCreated = dateCreated
    }
}
