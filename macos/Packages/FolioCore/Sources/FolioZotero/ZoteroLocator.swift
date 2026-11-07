import Foundation

/// Locates a Zotero data directory. Only ever reads files — never writes into `~/Zotero`.
public enum ZoteroLocator {
    /// Reads `extensions.zotero.dataDir` from the user's Zotero profile
    /// (`~/Library/Application Support/Zotero/Profiles/*/prefs.js`); falls back to `~/Zotero`.
    public static func defaultDataDirectory() -> URL? {
        if let fromPrefs = dataDirectoryFromPrefs(), directoryExists(fromPrefs) {
            return fromPrefs
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Zotero")
        return directoryExists(fallback) ? fallback : nil
    }

    /// The `extensions.zotero.baseAttachmentPath` preference, used to resolve linked
    /// attachments stored with an `attachments:`-relative path.
    public static func baseAttachmentPath() -> String? {
        pref(named: "extensions.zotero.baseAttachmentPath").flatMap(unquote)
    }

    static func dataDirectoryFromPrefs() -> URL? {
        guard let raw = pref(named: "extensions.zotero.dataDir"), let value = unquote(raw) else { return nil }
        return URL(fileURLWithPath: value)
    }

    static func pref(named name: String) -> String? {
        for profile in profilePrefsFiles() {
            guard let text = try? String(contentsOf: profile, encoding: .utf8) else { continue }
            if let value = value(forPref: name, in: text) { return value }
        }
        return nil
    }

    static func profilePrefsFiles() -> [URL] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zotero/Profiles")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .map { $0.appendingPathComponent("prefs.js") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Extracts the raw (still-quoted) value of `user_pref("<name>", ...)` from prefs.js text.
    static func value(forPref name: String, in text: String) -> String? {
        let marker = "user_pref(\"\(name)\","
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        guard let semicolon = rest.firstIndex(of: ";") else { return nil }
        var segment = rest[..<semicolon].trimmingCharacters(in: .whitespaces)
        if segment.hasSuffix(")") { segment.removeLast() }
        return segment.trimmingCharacters(in: .whitespaces)
    }

    static func unquote(_ value: String) -> String? {
        var s = value
        guard s.count >= 2, s.first == "\"", s.last == "\"" else { return nil }
        s.removeFirst()
        s.removeLast()
        return s.replacingOccurrences(of: "\\\"", with: "\"")
    }

    static func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
