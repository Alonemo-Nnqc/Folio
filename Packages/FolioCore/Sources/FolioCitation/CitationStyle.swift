/// A citation format that `CSLRenderer` and `BibTeXWriter` can produce (requirement CITE-01).
public enum CitationStyle: String, CaseIterable, Sendable {
    case bibtex
    case gbt7714
    case apa

    public var displayName: String {
        switch self {
        case .bibtex: "BibTeX"
        case .gbt7714: "GB/T 7714-2015"
        case .apa: "APA 第 7 版"
        }
    }
}
