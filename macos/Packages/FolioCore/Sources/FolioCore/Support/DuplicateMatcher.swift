/// Decides whether two metadata records describe the same work (requirement DUP-03).
public enum DuplicateMatcher {
    public static func isSameWork(_ a: Metadata, _ b: Metadata) -> Bool {
        if let da = a.doi?.lowercased(), let db = b.doi?.lowercased(), !da.isEmpty, !db.isEmpty {
            return da == db
        }
        if let xa = a.arxivId?.lowercased(), let xb = b.arxivId?.lowercased(), !xa.isEmpty, xa == xb {
            return true
        }
        let ta = TitleNormalizer.normalize(a.title)
        guard !ta.isEmpty, ta == TitleNormalizer.normalize(b.title), a.year == b.year else { return false }
        return firstAuthorKey(a) == firstAuthorKey(b)
    }

    static func firstAuthorKey(_ m: Metadata) -> String {
        TitleNormalizer.normalize(m.authors.first?.family ?? "")
    }
}
