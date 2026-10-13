import FolioCitation

/// Citation styles offered in menus (CITE-01, AI-07): every style FolioCitation renders, in its order.
typealias CitationStyleOption = CitationStyle

extension CitationStyle: @retroactive Identifiable {
    public var id: String { rawValue }
    var title: String { displayName }
    var style: CitationStyle { self }
}
