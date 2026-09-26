import AppKit
import FolioCore

enum CitationStyleOption: String, CaseIterable, Identifiable {
    case bibtex, gbt7714, apa
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bibtex: "BibTeX"
        case .gbt7714: "GB/T 7714-2015"
        case .apa: "APA 第 7 版"
        }
    }
}

extension AppModel {
    /// Items to cite: the selection, or the whole current view when nothing is selected (CITE-02).
    var citationTargets: [Item] {
        let ids = selectedItemIDs.isEmpty ? rows : rows.filter(selectedItemIDs.contains)
        return ids.compactMap { snapshot.items[$0] }.filter { $0.kind == .regular }
    }

    func copyCitations(style: CitationStyleOption, itemIds: [String]? = nil) {
        toasts.show("引用导出将在集成 FolioCitation 后可用", systemImage: "quote.opening")
    }

    func exportBibTeX(itemIds: [String]? = nil) {
        toasts.show("引用导出将在集成 FolioCitation 后可用", systemImage: "quote.opening")
    }
}
