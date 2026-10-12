import Foundation

/// How folio-cli finds the user's library and what it may do, read from Folio's own preferences so
/// the helper always follows the app (AI-01/04).
public struct AgentConfiguration: Sendable {
    public static let appDefaultsDomain = "com.nnqc.Folio"
    /// 设置 ▸ AI ▸ 允许 AI 修改文献库.
    public static let allowWritesKey = "aiAllowWrites"

    public var libraryRoot: URL
    public var allowWrites: Bool
    public var autoRenameFiles: Bool
    public var crossrefMailto: String?
    public var openAlexAPIKey: String?
    public var useZoteroRecognizer: Bool

    public init(libraryRoot: URL, allowWrites: Bool = true, autoRenameFiles: Bool = true, crossrefMailto: String? = nil,
                openAlexAPIKey: String? = nil, useZoteroRecognizer: Bool = true) {
        self.libraryRoot = libraryRoot
        self.allowWrites = allowWrites
        self.autoRenameFiles = autoRenameFiles
        self.crossrefMailto = crossrefMailto
        self.openAlexAPIKey = openAlexAPIKey
        self.useZoteroRecognizer = useZoteroRecognizer
    }

    /// `--library <dir>` > `FOLIO_LIBRARY` > Folio's preference > `~/Folio`.
    public static func resolve(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment)
        -> AgentConfiguration {
        let defaults = UserDefaults(suiteName: appDefaultsDomain)
        var path: String?
        if let index = arguments.firstIndex(of: "--library"), arguments.indices.contains(index + 1) {
            path = arguments[index + 1]
        }
        path = path ?? environment["FOLIO_LIBRARY"] ?? defaults?.string(forKey: "libraryPath")
        let root = URL(filePath: ((path ?? "~/Folio") as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        func flag(_ key: String, default value: Bool) -> Bool {
            defaults?.object(forKey: key) == nil ? value : defaults!.bool(forKey: key)
        }
        func text(_ key: String) -> String? {
            defaults?.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
        }
        let readOnly = arguments.contains("--read-only") || environment["FOLIO_READ_ONLY"] == "1"
        return AgentConfiguration(libraryRoot: root,
                                  allowWrites: !readOnly && flag(allowWritesKey, default: true),
                                  autoRenameFiles: flag("autoRenameFiles", default: true),
                                  crossrefMailto: text("crossrefMailto"),
                                  openAlexAPIKey: text("openAlexAPIKey"),
                                  useZoteroRecognizer: flag("useZoteroRecognizer", default: true))
    }
}
