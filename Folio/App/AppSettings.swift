import Foundation
import Observation

/// Durable user preferences (requirement 4.16), persisted in UserDefaults.
@Observable
final class AppSettings {
    enum OpenWith: String, CaseIterable, Identifiable {
        case folio, system, preview, custom
        var id: String { rawValue }
        var title: String {
            switch self {
            case .folio: "Folio 阅读器"
            case .system: "系统默认应用"
            case .preview: "预览"
            case .custom: "指定应用…"
            }
        }
    }

    /// Zoom a paper opens with when it has no remembered position (设置 ▸ 阅读).
    enum ReaderZoom: String, CaseIterable, Identifiable {
        case fitWidth, actualSize
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fitWidth: "适合页宽"
            case .actualSize: "实际大小"
            }
        }
    }

    enum ReaderLayout: String, CaseIterable, Identifiable {
        case single, twoUp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .single: "单页连续"
            case .twoUp: "双页连续"
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
        static let openAlexAPIKey = "openAlexAPIKey"
        static let libraryPath = "libraryPath"
        static let readerZoom = "readerZoom"
        static let readerLayout = "readerLayout"
        static let reopenReaderTabs = "reopenReaderTabs"
        static let highlightColor = "highlightColor"
        static let useZoteroRecognizer = "useZoteroRecognizer"
    }

    private let defaults: UserDefaults

    var openWith: OpenWith { didSet { defaults.set(openWith.rawValue, forKey: Key.openWith) } }
    var openWithAppPath: String { didSet { defaults.set(openWithAppPath, forKey: Key.openWithAppPath) } }
    var includeSubgroupItems: Bool { didSet { defaults.set(includeSubgroupItems, forKey: Key.includeSubgroupItems) } }
    var autoRenameFiles: Bool { didSet { defaults.set(autoRenameFiles, forKey: Key.autoRenameFiles) } }
    var autoPurgeTrash: Bool { didSet { defaults.set(autoPurgeTrash, forKey: Key.autoPurgeTrash) } }
    var crossrefMailto: String { didSet { defaults.set(crossrefMailto, forKey: Key.crossrefMailto) } }
    var openAlexAPIKey: String { didSet { defaults.set(openAlexAPIKey, forKey: Key.openAlexAPIKey) } }
    var libraryPath: String { didSet { defaults.set(libraryPath, forKey: Key.libraryPath) } }
    var readerZoom: ReaderZoom { didSet { defaults.set(readerZoom.rawValue, forKey: Key.readerZoom) } }
    var readerLayout: ReaderLayout { didSet { defaults.set(readerLayout.rawValue, forKey: Key.readerLayout) } }
    var reopenReaderTabs: Bool { didSet { defaults.set(reopenReaderTabs, forKey: Key.reopenReaderTabs) } }
    /// Name of the default highlight colour (see AnnotationColor).
    var highlightColor: String { didSet { defaults.set(highlightColor, forKey: Key.highlightColor) } }
    var useZoteroRecognizer: Bool { didSet { defaults.set(useZoteroRecognizer, forKey: Key.useZoteroRecognizer) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.openWith: OpenWith.folio.rawValue,
            Key.includeSubgroupItems: true,
            Key.autoRenameFiles: true,
            Key.autoPurgeTrash: true,
            Key.libraryPath: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Folio").path,
            Key.readerZoom: ReaderZoom.fitWidth.rawValue,
            Key.readerLayout: ReaderLayout.single.rawValue,
            Key.reopenReaderTabs: true,
            Key.highlightColor: "yellow",
            Key.useZoteroRecognizer: true,
        ])
        openWith = OpenWith(rawValue: defaults.string(forKey: Key.openWith) ?? "") ?? .folio
        openWithAppPath = defaults.string(forKey: Key.openWithAppPath) ?? ""
        includeSubgroupItems = defaults.bool(forKey: Key.includeSubgroupItems)
        autoRenameFiles = defaults.bool(forKey: Key.autoRenameFiles)
        autoPurgeTrash = defaults.bool(forKey: Key.autoPurgeTrash)
        crossrefMailto = defaults.string(forKey: Key.crossrefMailto) ?? ""
        openAlexAPIKey = defaults.string(forKey: Key.openAlexAPIKey) ?? ""
        readerZoom = ReaderZoom(rawValue: defaults.string(forKey: Key.readerZoom) ?? "") ?? .fitWidth
        readerLayout = ReaderLayout(rawValue: defaults.string(forKey: Key.readerLayout) ?? "") ?? .single
        reopenReaderTabs = defaults.bool(forKey: Key.reopenReaderTabs)
        highlightColor = defaults.string(forKey: Key.highlightColor) ?? "yellow"
        useZoteroRecognizer = defaults.bool(forKey: Key.useZoteroRecognizer)
        // A `-FolioLibraryPath <dir>` launch argument (UI tests) overrides the stored location.
        libraryPath = defaults.volatileDomain(forName: UserDefaults.argumentDomain)["FolioLibraryPath"] as? String
            ?? defaults.string(forKey: Key.libraryPath)!
    }

    var libraryURL: URL { URL(filePath: (libraryPath as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
}
