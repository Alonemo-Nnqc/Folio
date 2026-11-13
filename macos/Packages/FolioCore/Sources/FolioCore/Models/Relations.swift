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

    init(scope: String, sortColumn: SortColumn?, ascending: Bool) {
        self.scope = scope
        self.sortColumn = sortColumn
        self.ascending = ascending
    }

    /// A column this version does not know (saved by a newer Folio, on either platform) reads as the custom order
    /// instead of failing the whole snapshot.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scope = try container.decode(String.self, forKey: .scope)
        sortColumn = try container.decodeIfPresent(String.self, forKey: .sortColumn).flatMap(SortColumn.init(rawValue:))
        ascending = try container.decode(Bool.self, forKey: .ascending)
    }
}
