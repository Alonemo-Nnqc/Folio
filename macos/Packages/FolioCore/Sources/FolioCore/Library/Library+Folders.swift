import Foundation
import GRDB

/// A folder dropped on Folio, with what can be imported from it: it becomes a group, its subfolders that group's subgroups.
public struct ImportFolder: Sendable, Equatable {
    public var name: String
    public var files: [URL]
    public var children: [ImportFolder]

    public init(name: String, files: [URL] = [], children: [ImportFolder] = []) {
        self.name = name
        self.files = files
        self.children = children
    }

    public var fileCount: Int { children.reduce(files.count) { $0 + $1.fileCount } }
    /// Everything in it, whatever folder it is in.
    public var allFiles: [URL] { files + children.flatMap(\.allFiles) }

    /// What is taken from folders: papers and Markdown documents.
    public static let extensions: Set<String> = ["pdf", "md", "markdown"]

    /// Reads a folder (hidden files, packages and links to other folders aside); folders with nothing to import are left out.
    /// Nil when there is nothing at all.
    public static func scan(_ url: URL, depth: Int = 0) -> ImportFolder? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard depth < 24, let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        var folder = ImportFolder(name: url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines))
        for entry in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if values?.isPackage != true, values?.isSymbolicLink != true, let child = scan(entry, depth: depth + 1) { folder.children.append(child) }
            } else if extensions.contains(entry.pathExtension.lowercased()) {
                folder.files.append(entry)
            }
        }
        return folder.files.isEmpty && folder.children.isEmpty ? nil : folder
    }
}

public struct FolderImportResult: Sendable {
    /// The group the folder became (an existing one of the same name in the same place is gone on with). Nil at the last level
    /// groups have: its files went to the group they were dropped on.
    public var groupId: String?
    public var outcomes: [ImportOutcome] = []
}

extension Library {
    /// Imports a folder as a group under `parentId` (nil: the top level), at `index` among its groups (nil: the end). Folders
    /// deeper than groups go are put in the last level's group.
    public func importFolder(_ folder: ImportFolder, parentId: String? = nil, index: Int? = nil) throws -> FolderImportResult {
        var result = FolderImportResult()
        let depth = try parentId.map { id in try writer.read { try Self.depth(of: id, $0) } } ?? 0
        guard depth < LibraryGroup.maximumDepth else {
            result.outcomes = try importFiles(folder.allFiles, toGroup: parentId)
            return result
        }
        let name = folder.name.isEmpty ? "Folder" : folder.name
        let siblings = try writer.read { try Self.siblings(of: parentId, $0) }
        let group: LibraryGroup
        if let known = siblings.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            group = known
        } else {
            group = try createGroup(name: name, parentId: parentId)
            if let index, index < siblings.count { try moveGroup(group.id, toParent: parentId, index: index) }
        }
        result.groupId = group.id
        result.outcomes = try importFiles(folder.files, toGroup: group.id)
        // What is in the trash will be in the group once it is put back.
        let trashed = result.outcomes.compactMap { if case .duplicateInTrash(let id) = $0 { id } else { nil } }
        if !trashed.isEmpty {
            try writer.write { db in
                for id in trashed { try ItemGroup(itemId: id, groupId: group.id, dateAdded: Date()).insert(db, onConflict: .ignore) }
            }
        }
        for child in folder.children {
            result.outcomes += try importFolder(child, parentId: group.id).outcomes
        }
        return result
    }
}
