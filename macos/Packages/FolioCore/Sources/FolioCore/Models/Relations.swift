import Foundation
import GRDB

struct ItemGroup: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemGroup"
    var itemId: String
    var groupId: String
    var dateAdded: Date
}

struct ItemTag: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemTag"
    var itemId: String
    var tagId: String
}

struct ItemOrder: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "itemOrder"
    var scope: String
    var itemId: String
    var position: Double
}

struct ViewSortRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "viewSort"
    var scope: String
    var sortColumn: SortColumn?
    var ascending: Bool
}
