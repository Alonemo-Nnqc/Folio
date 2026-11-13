import AppKit
import FolioAgent
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
            case .folio: String(localized: "Folio 阅读器")
            case .system: String(localized: "系统默认应用")
            case .preview: String(localized: "预览")
            case .custom: String(localized: "指定应用…")
            }
        }
    }

    /// Zoom a paper opens with when it has no remembered position (设置 ▸ 阅读).
    enum ReaderZoom: String, CaseIterable, Identifiable {
        case fitWidth, actualSize
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fitWidth: String(localized: "适合页宽")
            case .actualSize: String(localized: "实际大小")
            }
        }
    }

    enum ReaderLayout: String, CaseIterable, Identifiable {
        case single, twoUp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .single: String(localized: "单页连续")
            case .twoUp: String(localized: "双页连续")
            }
        }
    }

    /// 设置 ▸ 外观: follow the system, or force light / dark.
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: String(localized: "自动")
            case .light: String(localized: "浅色")
            case .dark: String(localized: "深色")
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// 划词翻译: when a selection in the reader is translated.
    enum SelectionTrigger: String, CaseIterable, Identifiable {
        /// A small button appears beside the selection; a click (or the shortcut) translates.
        case button
        /// Translated as soon as the mouse is released.
        case automatic
        /// Only with the shortcut or the context menu.
        case shortcut
        var id: String { rawValue }
        var title: String {
            switch self {
            case .button: String(localized: "选中后显示翻译按钮")
            case .automatic: String(localized: "选中后自动翻译")
            case .shortcut: String(localized: "仅使用快捷键")
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
        static let readerEraserSize = "readerEraserSize"
        static let useZoteroRecognizer = "useZoteroRecognizer"
        static let translationService = "translationService"
        static let translationFields = "translationFields"
        static let translationOptions = "translationOptions"
        static let translationProfiles = "translationProfiles"
        static let selectedTranslationProfiles = "selectedTranslationProfiles"
        static let appearance = "appearance"
        static let markReadingOnOpen = "markReadingOnOpen"
        static let readerPageShadows = "readerPageShadows"
        static let annotationAuthor = "annotationAuthor"
        static let autoRetrieveOnImport = "autoRetrieveOnImport"
        static let aiAllowWrites = "aiAllowWrites"
        static let browserConnectorEnabled = "browserConnectorEnabled"
        static let selectionTranslationEnabled = "selectionTranslationEnabled"
        static let selectionTranslationTrigger = "selectionTranslationTrigger"
        static let selectionTranslationService = "selectionTranslationService"
        static let selectionTranslationShortcut = "selectionTranslationShortcut"
        static let backgroundTranslucency = "backgroundTranslucency"
        static let translationParallelJobs = "translationParallelJobs"
        static let selectionTranslationFallback = "selectionTranslationFallback"
        static let journalMetricsAutoFetch = "journalMetricsAutoFetch"
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
    /// The reader's eraser size (READER-30): small, medium or large (see InkEraser.Size).
    var readerEraserSize: String { didSet { save(readerEraserSize, Key.readerEraserSize) } }
    var useZoteroRecognizer: Bool { didSet { save(useZoteroRecognizer, Key.useZoteroRecognizer) } }
    /// Translation service id from `TranslationServiceCatalog` (TRANS-03).
    var translationService: String { didSet { save(translationService, Key.translationService) } }
    /// Non-secret field values per service: service id → CLI option → value. Secrets live in the Keychain.
    var translationFields: [String: [String: String]] {
        didSet {
            save(translationFields, Key.translationFields)
            syncSelectedProfiles()
        }
    }
    /// Saved configurations of translation services (several OpenAI-compatible providers…); keys in the Keychain.
    var translationProfiles: [TranslationProfile] {
        didSet { save(try? JSONEncoder().encode(translationProfiles), Key.translationProfiles) }
    }
    /// The configuration in use per service: service id → profile id. None: the values are not saved as one.
    var selectedTranslationProfiles: [String: String] {
        didSet { save(selectedTranslationProfiles, Key.selectedTranslationProfiles) }
    }

    /// Edits of a service's values (fields, model list, reasoning effort) go into the configuration in use.
    private func syncSelectedProfiles() {
        for (serviceID, profileID) in selectedTranslationProfiles {
            guard let index = translationProfiles.firstIndex(where: { $0.id == profileID }) else { continue }
            let current = (translationFields[serviceID] ?? [:]).filter { !$0.value.isEmpty }
            if translationProfiles[index].fields != current { translationProfiles[index].fields = current }
        }
    }
    var translationOptions: TranslationOptions {
        didSet { save(try? JSONEncoder().encode(translationOptions), Key.translationOptions) }
    }
    var appearance: Appearance {
        didSet {
            save(appearance.rawValue, Key.appearance)
            NSApp.appearance = appearance.nsAppearance
        }
    }
    /// Opening an unread paper marks it as being read (OPEN-03).
    var markReadingOnOpen: Bool { didSet { save(markReadingOnOpen, Key.markReadingOnOpen) } }
    var readerPageShadows: Bool { didSet { save(readerPageShadows, Key.readerPageShadows) } }
    /// Author written into new annotations (Preview shows it in its annotation list).
    var annotationAuthor: String { didSet { save(annotationAuthor, Key.annotationAuthor) } }
    /// Look up metadata as soon as a PDF is added (META-01); off = only on request.
    var autoRetrieveOnImport: Bool { didSet { save(autoRetrieveOnImport, Key.autoRetrieveOnImport) } }
    /// 设置 ▸ AI: AI agents may change the library (folio-cli reads the same key).
    var aiAllowWrites: Bool { didSet { save(aiAllowWrites, Key.aiAllowWrites) } }
    /// 设置 ▸ 浏览器: the local service the browser extension saves through (WEB-01).
    var browserConnectorEnabled: Bool { didSet { save(browserConnectorEnabled, Key.browserConnectorEnabled) } }

    /// 划词翻译 in the reader (TRANS-10).
    var selectionTranslationEnabled: Bool { didSet { save(selectionTranslationEnabled, Key.selectionTranslationEnabled) } }
    var selectionTranslationTrigger: SelectionTrigger { didSet { save(selectionTranslationTrigger.rawValue, Key.selectionTranslationTrigger) } }
    /// Service of 划词翻译; empty: the full-text translation's service.
    var selectionTranslationService: String { didSet { save(selectionTranslationService, Key.selectionTranslationService) } }
    var selectionTranslationShortcut: KeyShortcut { didSet { save(selectionTranslationShortcut.storage, Key.selectionTranslationShortcut) } }
    /// 划词翻译: a rate-limited free service hands over to another free one.
    var selectionTranslationFallback: Bool { didSet { save(selectionTranslationFallback, Key.selectionTranslationFallback) } }
    /// The service 划词翻译 uses now.
    var effectiveSelectionService: String {
        selectionTranslationService.isEmpty ? translationService : TranslationServiceCatalog.resolve(selectionTranslationService).id
    }
    /// 设置 ▸ 通用 ▸ 背景透明度: 0 opaque (the standard look), 1 the desktop shows through the list, inspector and reader.
    var backgroundTranslucency: Double { didSet { save(backgroundTranslucency, Key.backgroundTranslucency) } }
    /// Papers translated at the same time (设置 ▸ 翻译 ▸ 同时翻译); the rest wait their turn.
    var translationParallelJobs: Int { didSet { save(translationParallelJobs, Key.translationParallelJobs) } }
    /// 设置 ▸ 检索 ▸ 期刊指标: look up the ranks of new and changed items' journals by itself (META-30).
    var journalMetricsAutoFetch: Bool { didSet { save(journalMetricsAutoFetch, Key.journalMetricsAutoFetch) } }

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
            Key.markReadingOnOpen: true,
            Key.readerPageShadows: true,
            Key.annotationAuthor: NSFullUserName(),
            Key.autoRetrieveOnImport: true,
            Key.aiAllowWrites: true,
            Key.browserConnectorEnabled: true,
            Key.selectionTranslationEnabled: true,
            Key.selectionTranslationTrigger: SelectionTrigger.button.rawValue,
            Key.backgroundTranslucency: 0.0,
            Key.translationParallelJobs: 2,
            Key.selectionTranslationFallback: true,
            Key.journalMetricsAutoFetch: true,
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
        readerEraserSize = defaults.string(forKey: Key.readerEraserSize) ?? "medium"
        useZoteroRecognizer = defaults.bool(forKey: Key.useZoteroRecognizer)
        // Services of the old pdf2zh_next engine that are gone map to their replacement.
        translationService = TranslationServiceCatalog.resolve(defaults.string(forKey: Key.translationService) ?? TranslationServiceCatalog.defaultServiceID).id
        translationFields = defaults.dictionary(forKey: Key.translationFields) as? [String: [String: String]] ?? [:]
        translationOptions = defaults.data(forKey: Key.translationOptions)
            .flatMap { try? JSONDecoder().decode(TranslationOptions.self, from: $0) } ?? TranslationOptions()
        translationProfiles = defaults.data(forKey: Key.translationProfiles)
            .flatMap { try? JSONDecoder().decode([TranslationProfile].self, from: $0) } ?? []
        selectedTranslationProfiles = defaults.dictionary(forKey: Key.selectedTranslationProfiles) as? [String: String] ?? [:]
        markReadingOnOpen = defaults.bool(forKey: Key.markReadingOnOpen)
        readerPageShadows = defaults.bool(forKey: Key.readerPageShadows)
        annotationAuthor = defaults.string(forKey: Key.annotationAuthor) ?? NSFullUserName()
        autoRetrieveOnImport = defaults.bool(forKey: Key.autoRetrieveOnImport)
        aiAllowWrites = defaults.bool(forKey: Key.aiAllowWrites)
        browserConnectorEnabled = defaults.bool(forKey: Key.browserConnectorEnabled)
        selectionTranslationEnabled = defaults.bool(forKey: Key.selectionTranslationEnabled)
        selectionTranslationTrigger = SelectionTrigger(rawValue: defaults.string(forKey: Key.selectionTranslationTrigger) ?? "") ?? .button
        selectionTranslationService = defaults.string(forKey: Key.selectionTranslationService) ?? ""
        selectionTranslationShortcut = KeyShortcut(storage: defaults.dictionary(forKey: Key.selectionTranslationShortcut)) ?? .defaultSelectionTranslation
        selectionTranslationFallback = defaults.bool(forKey: Key.selectionTranslationFallback)
        translationParallelJobs = defaults.integer(forKey: Key.translationParallelJobs)
        journalMetricsAutoFetch = defaults.bool(forKey: Key.journalMetricsAutoFetch)
        backgroundTranslucency = min(1, max(0, defaults.double(forKey: Key.backgroundTranslucency)))
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        // A `-FolioLibraryPath <dir>` launch argument (UI tests) overrides the stored location.
        libraryPath = defaults.volatileDomain(forName: UserDefaults.argumentDomain)["FolioLibraryPath"] as? String
            ?? defaults.string(forKey: Key.libraryPath)!
    }

    var libraryURL: URL { URL(filePath: (libraryPath as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
}
