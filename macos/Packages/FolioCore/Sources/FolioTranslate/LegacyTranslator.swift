import Foundation

/// The pdf2zh_next engine earlier versions downloaded (Python, packages, layout models: about 1.4 GB). The native
/// engine does not use it; settings offer to delete it.
public enum LegacyTranslator {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Folio/Translator", directoryHint: .isDirectory)
    }

    public static var exists: Bool { FileManager.default.fileExists(atPath: directory.path) }

    /// Bytes on disk.
    public static func size() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Deletes it, including files uv left read-only.
    public static func remove() throws {
        guard exists else { return }
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        try FileManager.default.removeItem(at: directory)
    }
}
