import Foundation

/// Which identifiers found in a PDF are worth a lookup: at most 3 DOIs, 1 arXiv ID and 1 ISBN.
struct LookupPlan: Sendable, Equatable {
    static let maxDOIs = 3

    var identifiers: [FoundIdentifier]
    var pdfHasArxivID: Bool

    init(found: [FoundIdentifier]) {
        let arxiv = found.first { $0.isArxiv && $0.isSelfDescribing } ?? found.first(where: \.isArxiv)
        let arxivID: String? = if case .arxiv(let id)? = arxiv?.identifier { id } else { nil }

        // An arXiv DOI of the same paper would only duplicate the arXiv lookup.
        let dois = found.filter { candidate in
            guard case .doi(let doi) = candidate.identifier else { return false }
            return arxivID == nil || IdentifierExtractor.arxivID(fromDOI: doi) != arxivID
        }
        var chosen = Array(dois.prefix(Self.maxDOIs))
        // Never drop the PDF's own DOI (from its metadata) in favour of DOIs cited in the text.
        if let own = dois.first(where: \.isSelfDescribing), !chosen.contains(own), !chosen.isEmpty {
            chosen[chosen.count - 1] = own
        }
        if let arxiv { chosen.append(arxiv) }
        if let isbn = found.first(where: \.isISBN) { chosen.append(isbn) }

        identifiers = chosen
        pdfHasArxivID = arxiv != nil
    }
}

extension FoundIdentifier {
    var isArxiv: Bool {
        if case .arxiv = identifier { true } else { false }
    }

    var isISBN: Bool {
        if case .isbn = identifier { true } else { false }
    }
}
