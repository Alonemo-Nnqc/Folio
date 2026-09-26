import Foundation

/// Manages the flat `Files/` folder inside the library root.
struct FileStore: Sendable {
    static let folderName = "Files"
    let root: URL

    var filesDirectory: URL { root.appending(path: Self.folderName, directoryHint: .isDirectory) }

    func url(for relativePath: String) -> URL {
        root.appending(path: relativePath, directoryHint: .notDirectory)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
    }

    /// Copies `source` in under `baseName.ext`, adding " 2", " 3"… on collisions. Returns the relative path.
    func copyIn(_ source: URL, baseName: String, ext: String) throws -> String {
        let relative = uniqueRelativePath(baseName: baseName, ext: ext, ignoring: nil)
        try FileManager.default.copyItem(at: source, to: url(for: relative))
        return relative
    }

    /// Renames an existing file to `baseName.ext` (keeping it if the name is unchanged).
    func rename(_ relativePath: String, toBaseName baseName: String) throws -> String {
        let ext = (relativePath as NSString).pathExtension
        let target = uniqueRelativePath(baseName: baseName, ext: ext, ignoring: relativePath)
        guard target != relativePath else { return relativePath }
        try FileManager.default.moveItem(at: url(for: relativePath), to: url(for: target))
        return target
    }

    func delete(_ relativePath: String) {
        try? FileManager.default.removeItem(at: url(for: relativePath))
    }

    func uniqueRelativePath(baseName: String, ext: String, ignoring current: String?) -> String {
        let base = baseName.isEmpty ? "Untitled" : baseName
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base) \(index)"
            let fileName = ext.isEmpty ? name : "\(name).\(ext)"
            let relative = "\(Self.folderName)/\(fileName)"
            if relative == current { return relative }
            if !FileManager.default.fileExists(atPath: url(for: relative).path) { return relative }
            index += 1
        }
    }
}
