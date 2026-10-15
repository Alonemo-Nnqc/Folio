import AppKit
import FolioCore
import FolioTranslate
import Foundation

/// Launch-argument hooks that put the window into a given state, so UI can be checked from
/// screenshots without clicking. Read once after the library loads; no effect in normal use.
///
///   -FolioPreviewScope   all | unfiled | trash | group:<name> | tag:<name>
///   -FolioPreviewSelect  <title prefix>          selects the first matching item
///   -FolioPreviewExpand  YES                     expands the selected item
///   -FolioPreviewSearch  <text>                  opens the search field with text
///   -FolioPreviewTab     metadata | annotations | notes   inspector tab
///   -FolioPreviewSheet   tagEditor | tagEdit | zotero | identifier | manualMatch
///   -FolioPreviewDrop    <file count>            shows the Finder drop overlay
///   -FolioPreviewToast   <text>
///   -FolioPreviewOpenReader <title prefix>      opens that item's PDF in a reader tab
///   -FolioTranslateSelfTest <log>               with Select: translate page 1 via the real coordinator
///   -FolioPreviewParallel YES                   with OpenReader: turn on 对照阅读
///   -FolioReaderSelfTest <log>                  with OpenReader: scripted annotation/save/position checks
///   -FolioPreviewExpandGroups YES               expands every group in the sidebar
///   -FolioPreviewCollapseSidebar YES            hides the sidebar
///   -FolioPreviewSettings <pane title>          opens the Settings window on that pane (e.g. 通用)
///   -FolioPreviewFocusedSelection YES           list selection drawn as if the list had focus
///   -FolioPreviewSnapshot <png>                 draws the window into a PNG (works while the screen is locked)
///   -FolioPreviewSnapshotDelay <seconds>        when to draw it (default 3)
///   -FolioPreviewTranslating <title prefix>    shows that item as being translated (42%)
///   -FolioPreviewTranslationProfiles YES        two sample translation configurations (in memory)
///   -FolioPreviewProfileEditor YES              with Settings 翻译: opens 编辑配置…
enum PreviewHooks {
    private static var defaults: UserDefaults { .standard }

    static func apply(to model: AppModel) {
        let s = model.snapshot
        if let scope = defaults.string(forKey: "FolioPreviewScope") {
            if scope == "unfiled" { model.sidebarSelection = .unfiled }
            else if scope == "trash" { model.sidebarSelection = .trash }
            else if scope.hasPrefix("group:"), let group = s.groupsById.values.first(where: { $0.name == scope.dropFirst(6) }) {
                model.sidebarSelection = .group(group.id)
            } else if scope.hasPrefix("tag:"), let tag = s.tags.first(where: { $0.name == scope.dropFirst(4) }) {
                model.sidebarSelection = .tag(tag.id)
            }
        }
        if let text = defaults.string(forKey: "FolioPreviewSearch") {
            model.search = SearchState(text: text)
        }
        if let prefix = defaults.string(forKey: "FolioPreviewSelect"),
           let id = model.rows.first(where: { s.items[$0]?.title.hasPrefix(prefix) ?? false }) {
            model.selectedItemIDs = [id]
            if defaults.bool(forKey: "FolioPreviewExpand") { model.previewExpandRequest = id }
            if let log = defaults.string(forKey: "FolioTranslateSelfTest") {
                TranslationSelfTest.run(model: model, itemId: id, log: log)
            }
        }
        if let prefix = defaults.string(forKey: "FolioPreviewTranslating"),
           let item = s.items.values.first(where: { $0.title.hasPrefix(prefix) }), let file = model.defaultFile(of: item.id) {
            model.translations.previewJob(itemId: item.id, fileId: file.id, stage: "翻译段落 34/120", fraction: 0.42)
        }
        if defaults.bool(forKey: "FolioPreviewTranslationProfiles") {
            // Two sample configurations of the current service, in memory only; the Keychain is not touched.
            let service = model.settings.translationService
            let profiles = [TranslationProfile(name: "DeepSeek", serviceID: service), TranslationProfile(name: "Moonshot", serviceID: service)]
            model.settings.translationProfiles = profiles
            model.settings.selectedTranslationProfiles[service] = profiles[0].id
        }
        if let tab = defaults.string(forKey: "FolioPreviewTab").flatMap(InspectorTab.init(rawValue:)) { model.inspectorTab = tab }
        switch defaults.string(forKey: "FolioPreviewSheet") {
        case "tagEditor": model.activeSheet = .tagEditor(tagId: nil, applyTo: [], initialName: "新论文方向")
        case "tagEdit": model.activeSheet = .tagEditor(tagId: s.tags.first?.id, applyTo: [])
        case "zotero": model.activeSheet = .zoteroImport
        case "identifier": model.activeSheet = .identifierAdd
        case "manualMatch": if let id = model.selectedItemIDs.first { model.activeSheet = .manualMatch(itemId: id) }
        default: break
        }
        let drop = defaults.integer(forKey: "FolioPreviewDrop")
        if drop > 0 { model.externalDropCount = drop }
        if let toast = defaults.string(forKey: "FolioPreviewToast") { model.toasts.show(toast, systemImage: "folder.badge.plus") }
        if defaults.bool(forKey: "FolioPreviewExpandGroups") { model.previewExpandAllGroups = true }
        if defaults.bool(forKey: "FolioPreviewCollapseSidebar") {
            AppDelegate.shared.libraryWindowController.splitViewController.toggleSidebar(nil)
        }
        if let pane = defaults.string(forKey: "FolioPreviewSettings") {
            AppDelegate.shared.showSettings(nil)
            AppDelegate.shared.settingsWindow?.select(pane: pane)
        }
        if let prefix = defaults.string(forKey: "FolioPreviewOpenReader"),
           let item = s.items.values.first(where: { $0.title.hasPrefix(prefix) }), let file = model.defaultFile(of: item.id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                model.open(fileId: file.id, mode: .reader)
                if defaults.bool(forKey: "FolioPreviewParallel") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        guard let reader = model.readers.reader(for: file.id) else { return }
                        reader.toggleParallelReading(nil)
                        if let log = defaults.string(forKey: "FolioParallelLog") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { reader.logParallelState(to: log) }
                        }
                    }
                }
                if let log = defaults.string(forKey: "FolioReaderSelfTest") {
                    ReaderSelfTest.run(model: model, fileId: file.id, log: log)
                }
            }
        }
        if let path = defaults.string(forKey: "FolioPreviewSnapshot") {
            let delay = defaults.double(forKey: "FolioPreviewSnapshotDelay")
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 3)) {
                let reader = NSApp.windows.first { $0.windowController is ReaderWindowController && $0.isVisible }
                let window = defaults.string(forKey: "FolioPreviewSettings") != nil ? AppDelegate.shared.settingsWindow?.window
                    : defaults.string(forKey: "FolioPreviewOpenReader") != nil ? reader : AppDelegate.shared.libraryWindowController.window
                // An open sheet (e.g. 编辑配置…) is what the window shows.
                guard let view = (window?.attachedSheet ?? window)?.contentView?.superview,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
            }
        }
        if let paths = defaults.string(forKey: "FolioPreviewSimulateDrop") {
            // "a.pdf|b.pdf": one drop per file, two seconds apart, to exercise repeated drops.
            for (index, path) in paths.split(separator: "|").map(String.init).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(index) * 2) { SimulatedDrop.run(path: path, model: model) }
            }
        }
    }
}
