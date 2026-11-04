import Foundation
import GRDB

public struct Tag: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tag"

    public var id: String
    public var name: String
    /// "#RRGGBB"
    public var colorHex: String
    public var position: Double

    public init(id: String = UUID().uuidString, name: String, colorHex: String, position: Double) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.position = position
    }
}
