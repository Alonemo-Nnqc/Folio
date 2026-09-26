import Foundation

/// A persistent identifier that can be resolved directly.
public enum Identifier: Sendable, Equatable {
    /// Lowercased, without resolver prefix: "10.1016/j.bspc.2024.106296".
    case doi(String)
    /// Without version suffix: "2604.27326" or "hep-th/9901001".
    case arxiv(String)
    /// Digits only (ISBN-10 may end in "X"): "9780262035613".
    case isbn(String)

    /// Recognises DOIs, arXiv IDs and ISBNs, bare or in their usual URL / prefixed forms:
    /// `doi:10.x/y`, `https://doi.org/10.x/y`, `arXiv:2604.27326v2`, `https://arxiv.org/abs/2604.27326`,
    /// `hep-th/9901001`, `ISBN 978-0-262-03561-3`, `https://openlibrary.org/isbn/9780262035613`.
    public static func parse(_ s: String) -> Identifier? {
        let raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.count <= 500 else { return nil }
        let text = raw.removingPercentEncoding ?? raw

        if let doi = IdentifierExtractor.dois(in: text).first {
            return .doi(doi)
        }
        if let arxiv = IdentifierExtractor.arxivIDs(in: text, requireContext: true).first {
            return .arxiv(arxiv)
        }
        if let isbn = IdentifierExtractor.isbns(in: text, requireKeyword: false).first,
           isbnOnly(text) {
            return .isbn(isbn)
        }
        // Bare arXiv IDs are only accepted when the whole input is the ID.
        if IdentifierExtractor.isBareArxivID(text) {
            let bare = text.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
            return .arxiv(IdentifierExtractor.arxivIDs(in: text, requireContext: false).first ?? bare)
        }
        return nil
    }

    /// True when `text` consists of an ISBN and nothing but ISBN decoration (prefix, URL, separators).
    private static func isbnOnly(_ text: String) -> Bool {
        var rest = text.lowercased()
        for noise in ["https://", "http://", "openlibrary.org/isbn/", "www.", "isbn-13", "isbn-10", "isbn", ".json", ":"] {
            rest = rest.replacingOccurrences(of: noise, with: "")
        }
        return rest.allSatisfy { $0.isNumber || $0 == "x" || $0 == "-" || $0 == " " || $0 == "/" }
    }
}
