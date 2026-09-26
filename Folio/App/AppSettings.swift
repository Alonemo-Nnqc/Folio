import Foundation
import Observation

/// Durable user preferences (requirement 4.16), persisted in UserDefaults.
@Observable
final class AppSettings {
    enum OpenWith: String, CaseIterable, Identifiable {
        case system, preview, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: "系统默认应用"
            case .preview: "预览"
            case .custom: "指定应用…"
            }
        }
    }

    private enum Key {
        static let openWith = "openWithMode"
        static let openWithAppPath = "openWithAppPath"
        static let includeSubgroupItems = "includeSubgroupItems"
        static let autoRenameFiles = "autoRenameFiles"
        static let autoPurgeTrash = "autoPurgeTrash"
        static let crossrefMailto = "crossrefMailto"
        static let libraryPath = "libraryPath"
    }

    private let defaults: UserDefaults

    var openWith: OpenWith { didSet { defaults.set(openWith.rawValue, forKey: Key.openWith) } }
    var openWithAppPath: String { didSet { defaults.set(openWithAppPath, forKey: Key.openWithAppPath) } }
    var includeSubgroupItems: Bool { didSet { defaults.set(includeSubgroupItems, forKey: Key.includeSubgroupItems) } }
    var autoRenameFiles: Bool { didSet { defaults.set(autoRenameFiles, forKey: Key.autoRenameFiles) } }
    var autoPurgeTrash: Bool { didSet { defaults.set(autoPurgeTrash, forKey: Key.autoPurgeTrash) } }
    var crossrefMailto: String { didSet { defaults.set(crossrefMailto, forKey: Key.crossrefMailto) } }
    var libraryPath: String { didSet { defaults.set(libraryPath, forKey: Key.libraryPath) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.openWith: OpenWith.system.rawValue,
            Key.includeSubgroupItems: true,
            Key.autoRenameFiles: true,
            Key.autoPurgeTrash: true,
            Key.libraryPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Folio").path,
        ])
        openWith = OpenWith(rawValue: defaults.string(forKey: Key.openWith) ?? "") ?? .system
        openWithAppPath = defaults.string(forKey: Key.openWithAppPath) ?? ""
        includeSubgroupItems = defaults.bool(forKey: Key.includeSubgroupItems)
        autoRenameFiles = defaults.bool(forKey: Key.autoRenameFiles)
        autoPurgeTrash = defaults.bool(forKey: Key.autoPurgeTrash)
        crossrefMailto = defaults.string(forKey: Key.crossrefMailto) ?? ""
        // A `-FolioLibraryPath <dir>` launch argument (UI tests) overrides the stored location.
        libraryPath = defaults.volatileDomain(forName: UserDefaults.argumentDomain)["FolioLibraryPath"] as? String
            ?? defaults.string(forKey: Key.libraryPath)!
    }

    var libraryURL: URL { URL(filePath: (libraryPath as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
}
