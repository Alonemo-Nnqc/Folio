import FolioTranslate
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
        static let translationService = "translationService"
        static let translationFields = "translationFields"
        static let translationOptions = "translationOptions"
        static let translatorCustomPath = "translatorCustomPath"
    }

    private let defaults: UserDefaults

    /// UI tests and screenshot runs (`-FolioUITesting YES`) change settings in memory only, so they
    /// never touch the user's real preferences.
    private func save(_ value: Any?, _ key: String) {
        guard !defaults.bool(forKey: "FolioUITesting") else { return }
        defaults.set(value, forKey: key)
    }

    var openWith: OpenWith { didSet { save(openWith.rawValue, Key.openWith) } }
    var openWithAppPath: String { didSet { save(openWithAppPath, Key.openWithAppPath) } }
    var includeSubgroupItems: Bool { didSet { save(includeSubgroupItems, Key.includeSubgroupItems) } }
    var autoRenameFiles: Bool { didSet { save(autoRenameFiles, Key.autoRenameFiles) } }
    var autoPurgeTrash: Bool { didSet { save(autoPurgeTrash, Key.autoPurgeTrash) } }
    var crossrefMailto: String { didSet { save(crossrefMailto, Key.crossrefMailto) } }
    var openAlexAPIKey: String { didSet { save(openAlexAPIKey, Key.openAlexAPIKey) } }
    var libraryPath: String { didSet { save(libraryPath, Key.libraryPath) } }
    var readerZoom: ReaderZoom { didSet { save(readerZoom.rawValue, Key.readerZoom) } }
    var readerLayout: ReaderLayout { didSet { save(readerLayout.rawValue, Key.readerLayout) } }
    var reopenReaderTabs: Bool { didSet { save(reopenReaderTabs, Key.reopenReaderTabs) } }
    /// Name of the default highlight colour (see AnnotationColor).
    var highlightColor: String { didSet { save(highlightColor, Key.highlightColor) } }
    var useZoteroRecognizer: Bool { didSet { save(useZoteroRecognizer, Key.useZoteroRecognizer) } }
    /// Translation service id from `TranslationServiceCatalog` (TRANS-03).
    var translationService: String { didSet { save(translationService, Key.translationService) } }
    /// Non-secret field values per service: service id → CLI option → value. Secrets live in the Keychain.
    var translationFields: [String: [String: String]] {
        didSet { save(translationFields, Key.translationFields) }
    }
    var translationOptions: TranslationOptions {
        didSet { save(try? JSONEncoder().encode(translationOptions), Key.translationOptions) }
    }
    /// A user-installed `pdf2zh_next`; empty = the copy Folio manages (TRANS-02).
    var translatorCustomPath: String { didSet { save(translatorCustomPath, Key.translatorCustomPath) } }

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
        translationService = defaults.string(forKey: Key.translationService) ?? TranslationServiceCatalog.defaultServiceID
        translationFields = defaults.dictionary(forKey: Key.translationFields) as? [String: [String: String]] ?? [:]
        translationOptions = defaults.data(forKey: Key.translationOptions)
            .flatMap { try? JSONDecoder().decode(TranslationOptions.self, from: $0) } ?? TranslationOptions()
        translatorCustomPath = defaults.string(forKey: Key.translatorCustomPath) ?? ""
        // A `-FolioLibraryPath <dir>` launch argument (UI tests) overrides the stored location.
        libraryPath = defaults.volatileDomain(forName: UserDefaults.argumentDomain)["FolioLibraryPath"] as? String
            ?? defaults.string(forKey: Key.libraryPath)!
    }

    var libraryURL: URL { URL(filePath: (libraryPath as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
}
