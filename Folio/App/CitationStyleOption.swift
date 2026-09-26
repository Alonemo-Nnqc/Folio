import FolioCitation

/// Citation styles offered in menus (CITE-01).
enum CitationStyleOption: String, CaseIterable, Identifiable {
    case bibtex, gbt7714, apa
    var id: String { rawValue }
    var title: String { style.displayName }

    var style: CitationStyle {
        switch self {
        case .bibtex: .bibtex
        case .gbt7714: .gbt7714
        case .apa: .apa
        }
    }
}
