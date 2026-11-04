import Foundation
import GRDB

public struct ReferenceImportResult: Sendable, Equatable {
    public var created: [String] = []
    /// Records that matched an item already in the library (by DOI, ISBN or title/year/author).
    public var duplicates: [String] = []
}

extension Library {
    /// Creates items for parsed references (AI-06). Duplicates are not created again but still join
    /// `groupId`; a reference's own citation key is kept when it is free.
    public func importReferences(_ references: [(metadata: Metadata, citationKey: String?)], toGroup groupId: String? = nil)
        throws -> ReferenceImportResult {
        var result = ReferenceImportResult()
        for reference in references {
            switch try createItem(reference.metadata, inGroup: groupId) {
            case .created(let id):
                result.created.append(id)
                if let key = reference.citationKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty {
                    try writer.write { db in
                        guard try !Self.existingCitationKeys(db).contains(key) else { return }
                        try db.execute(sql: "UPDATE item SET citationKey = ? WHERE id = ?", arguments: [key, id])
                    }
                }
            case .duplicate(let existing):
                result.duplicates.append(existing)
                if let groupId { _ = try addItems([existing], toGroup: groupId, includeSubgroups: false) }
            }
        }
        return result
    }
}
