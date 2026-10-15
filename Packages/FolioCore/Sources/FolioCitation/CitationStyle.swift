/// A citation format that `CSLRenderer` and `BibTeXWriter` can produce (requirements CITE-01, AI-07).
/// The order is the order of the "拷贝引用" menu.
public enum CitationStyle: String, CaseIterable, Sendable {
    case bibtex
    case gbt7714
    case apa
    case ieee
    case mla
    case chicago
    case harvard
    case vancouver
    case nature

    public var displayName: String {
        switch self {
        case .bibtex: "BibTeX"
        case .gbt7714: "GB/T 7714-2015"
        case .apa: String(localized: "APA 第 7 版", bundle: .module)
        case .ieee: "IEEE"
        case .mla: String(localized: "MLA 第 9 版", bundle: .module)
        case .chicago: String(localized: "Chicago 第 18 版（作者-日期）", bundle: .module)
        case .harvard: "Harvard"
        case .vancouver: "Vancouver"
        case .nature: "Nature"
        }
    }

    /// The bundled CSL file (without extension) from the official CSL styles repository; nil for BibTeX.
    var cslResource: String? {
        switch self {
        case .bibtex: nil
        case .gbt7714: "china-national-standard-gb-t-7714-2015-numeric"
        case .apa: "apa"
        case .ieee: "ieee"
        case .mla: "modern-language-association"
        case .chicago: "chicago-author-date"
        case .harvard: "harvard-cite-them-right"
        case .vancouver: "nlm-citation-sequence"
        case .nature: "nature"
        }
    }

    /// Names AI agents and the command line accept for each style (lowercased).
    public static func named(_ raw: String) -> CitationStyle? {
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        if let style = CitationStyle(rawValue: key) { return style }
        return switch key {
        case "gbt", "gb", "gbt77142015", "gb7714", "国标": .gbt7714
        case "apa7", "apa7th": .apa
        case "mla9", "mla9th", "modernlanguageassociation": .mla
        case "chicagoauthordate", "chicago18", "chicago17": .chicago
        case "citethemright", "harvardcitethemright": .harvard
        case "nlm", "icmje", "citingmedicine": .vancouver
        case "bib", "latex": .bibtex
        default: nil
        }
    }
}
