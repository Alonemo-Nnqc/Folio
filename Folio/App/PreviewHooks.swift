import AppKit
import FolioCore
import Foundation

/// Launch-argument hooks that put the window into a given state, so UI can be checked from
/// screenshots without clicking. Read once after the library loads; no effect in normal use.
///
///   -FolioPreviewScope   all | unfiled | trash | group:<name> | tag:<name>
///   -FolioPreviewSelect  <title prefix>          selects the first matching item
///   -FolioPreviewExpand  YES                     expands the selected item
///   -FolioPreviewSearch  <text>                  opens the search field with text
///   -FolioPreviewTab     annotations             inspector tab
///   -FolioPreviewSheet   tagEditor | tagEdit | zotero | identifier | manualMatch
///   -FolioPreviewDrop    <file count>            shows the Finder drop overlay
///   -FolioPreviewToast   <text>
///   -FolioPreviewExpandGroups YES               expands every group in the sidebar
///   -FolioPreviewSettings YES                   opens the Settings window
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
            model.search = SearchState(isVisible: true, text: text)
        }
        if let prefix = defaults.string(forKey: "FolioPreviewSelect"),
           let id = model.rows.first(where: { s.items[$0]?.title.hasPrefix(prefix) ?? false }) {
            model.selectedItemIDs = [id]
            if defaults.bool(forKey: "FolioPreviewExpand") { model.previewExpandRequest = id }
        }
        if defaults.string(forKey: "FolioPreviewTab") == "annotations" { model.previewInspectorTab = "annotations" }
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
        if defaults.bool(forKey: "FolioPreviewSettings") { model.previewOpenSettings = true }
        if let paths = defaults.string(forKey: "FolioPreviewSimulateDrop") {
            // "a.pdf|b.pdf": one drop per file, two seconds apart, to exercise repeated drops.
            for (index, path) in paths.split(separator: "|").map(String.init).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(index) * 2) { SimulatedDrop.run(path: path, model: model) }
            }
        }
    }
}
