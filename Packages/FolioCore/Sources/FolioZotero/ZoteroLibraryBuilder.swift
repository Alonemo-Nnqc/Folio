import Foundation
import FolioCore

/// Turns `RawZoteroLibrary` (plus read options) into the shared `PreparedLibrary` format and
/// a `ZoteroReadReport`. Pure function — no I/O.
enum ZoteroLibraryBuilder {
    private static let nonRegularTypeNames: Set<String> = ["attachment", "note", "annotation"]

    static func build(
        from raw: RawZoteroLibrary,
        dataDirectory: URL,
        baseAttachmentPath: String?,
        options: ZoteroReadOptions
    ) -> (PreparedLibrary, ZoteroReadReport) {
        var report = ZoteroReadReport()

        func typeName(_ id: Int64) -> String? { raw.itemTypeNameByID[id] }

        let flattened = ZoteroCollectionFlattening.flatten(raw.collections)
        report.collections = flattened.groups.count

        var collectionIDsByItem: [Int64: [Int64]] = [:]
        for (collectionID, itemIDs) in raw.itemIDsByCollection {
            for itemID in itemIDs { collectionIDsByItem[itemID, default: []].append(collectionID) }
        }

        func groupKeys(forItem itemID: Int64) -> [String] {
            var keys = Set<String>()
            for collectionID in collectionIDsByItem[itemID] ?? [] {
                if let key = flattened.exportKeyByCollectionID[collectionID] { keys.insert(key) }
            }
            return keys.sorted()
        }

        func tagNames(forItem itemID: Int64) -> [String] {
            guard let tags = raw.tagNamesByItem[itemID] else { return [] }
            var names = Set<String>()
            for tag in tags where tag.type == 0 || (tag.type == 1 && options.includeAutomaticTags) {
                names.insert(tag.name)
            }
            return names.sorted()
        }

        func resolvedFile(for attachment: RawAttachment) -> PreparedFile {
            let url = ZoteroAttachmentResolver.resolveURL(
                dataDirectory: dataDirectory, key: attachment.key,
                path: attachment.path, baseAttachmentPath: baseAttachmentPath
            )
            return PreparedFile(sourceURL: url, originalName: url.lastPathComponent, dateAdded: attachment.dateAdded)
        }

        // Attachments: sort into kept files (by parent, or standalone) vs. skip reasons.
        var keptFilesByParent: [Int64: [PreparedFile]] = [:]
        var keptStandalone: [RawAttachment] = []

        func classify(_ attachment: RawAttachment) {
            if raw.deletedItemIDs.contains(attachment.itemID) {
                report.skippedTrashed += 1
                return
            }
            switch attachment.linkMode {
            case ZoteroLinkMode.importedURL:
                report.skippedSnapshots += 1
            case ZoteroLinkMode.linkedURL:
                report.skippedLinks += 1
            default:
                if let parentItemID = attachment.parentItemID {
                    keptFilesByParent[parentItemID, default: []].append(resolvedFile(for: attachment))
                } else {
                    keptStandalone.append(attachment)
                }
            }
        }
        for (_, attachments) in raw.attachmentsByParent {
            for attachment in attachments { classify(attachment) }
        }
        for attachment in raw.standaloneAttachments { classify(attachment) }

        // Notes and annotations are identified purely by item type; trashed ones are counted
        // as trashed rather than double-counted under their own reason.
        for item in raw.items {
            guard let name = typeName(item.itemTypeID) else { continue }
            if name == "note" {
                if raw.deletedItemIDs.contains(item.itemID) { report.skippedTrashed += 1 } else { report.skippedNotes += 1 }
            } else if name == "annotation" {
                if raw.deletedItemIDs.contains(item.itemID) { report.skippedTrashed += 1 } else { report.skippedAnnotations += 1 }
            }
        }

        var entries: [PreparedEntry] = []
        var usedTagNames = Set<String>()

        for item in raw.items {
            guard let name = typeName(item.itemTypeID), !nonRegularTypeNames.contains(name) else { continue }
            if raw.deletedItemIDs.contains(item.itemID) {
                report.skippedTrashed += 1
                continue
            }
            let metadata = ZoteroMetadataBuilder.build(
                itemTypeName: name,
                fields: raw.fieldsByItem[item.itemID] ?? [:],
                creators: raw.creatorsByItem[item.itemID] ?? []
            )
            let files = ZoteroAttachmentResolver.order(keptFilesByParent[item.itemID] ?? [])
            let tags = tagNames(forItem: item.itemID)
            usedTagNames.formUnion(tags)
            entries.append(PreparedEntry(
                kind: .regular(metadata), files: files,
                groupKeys: groupKeys(forItem: item.itemID), tagNames: tags,
                dateAdded: item.dateAdded, dateModified: item.dateModified
            ))
            report.regularItems += 1
        }

        for attachment in keptStandalone {
            let tags = tagNames(forItem: attachment.itemID)
            usedTagNames.formUnion(tags)
            entries.append(PreparedEntry(
                kind: .standalone, files: [resolvedFile(for: attachment)],
                groupKeys: groupKeys(forItem: attachment.itemID), tagNames: tags,
                dateAdded: attachment.dateAdded, dateModified: attachment.dateModified
            ))
            report.standaloneFiles += 1
        }

        let tags = usedTagNames.sorted().map { name in
            PreparedTag(name: name, colorHex: raw.tagColors[name.lowercased()] ?? ZoteroTagColorParsing.defaultColorHex)
        }
        report.tags = tags.count
        report.automaticTagsAvailable = raw.automaticTagNames.count

        return (PreparedLibrary(groups: flattened.groups, tags: tags, entries: entries), report)
    }
}
