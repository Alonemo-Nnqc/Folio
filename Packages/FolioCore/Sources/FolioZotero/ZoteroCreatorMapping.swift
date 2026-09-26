import FolioCore

/// Maps Zotero "author" creators to `Author`, honouring `fieldMode == 1` (single-field /
/// organisation names, stored in `lastName`).
enum ZoteroCreatorMapping {
    static func authors(from creators: [RawCreator]) -> [Author] {
        creators.sorted { $0.orderIndex < $1.orderIndex }.map { creator in
            if creator.fieldMode == 1 {
                return Author(family: creator.lastName ?? creator.firstName ?? "")
            }
            return Author(family: creator.lastName ?? "", given: creator.firstName ?? "")
        }
    }
}
