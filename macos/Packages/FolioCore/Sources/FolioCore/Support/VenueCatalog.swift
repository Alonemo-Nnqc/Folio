import Foundation

/// The short name of where a paper appeared ("CVPR", "TPAMI", "Nature") and, for venues known to everyone in the
/// field, their CCF class, recognised from the item's own metadata: the venue's full name in 来源, an acronym in
/// it ("… (ICCV)"), or the DOI's venue part (10.1109/CVPR…). Nothing is fetched; venues not in the list get an
/// acronym of their name when it is long enough to need one.
public enum VenueCatalog {
    public struct Venue: Sendable, Hashable {
        /// The short name shown in the list.
        public var abbreviation: String
        /// The full name the abbreviation stands for (tooltip), when known.
        public var fullName: String?
        /// CCF class ("A", "B", "C") from the built-in list, when the venue is in it.
        public var ccf: String?
        /// True for conferences and workshops.
        public var isConference: Bool
    }

    private struct Entry {
        let abbreviation: String
        let name: String
        let ccf: String?
        let conference: Bool
        let patterns: [String]
        let doi: [String]
    }

    /// Well-known venues: (short name, full name, CCF class, conference?, name patterns, DOI venue codes).
    private static let entries: [Entry] = [
        // Computer vision
        Entry(abbreviation: "CVPR", name: "IEEE/CVF Conference on Computer Vision and Pattern Recognition", ccf: "A", conference: true,
              patterns: [#"computer vision and pattern recognition"#, #"\bcvpr\b"#], doi: ["cvpr"]),
        Entry(abbreviation: "CVPRW", name: "CVPR Workshops", ccf: nil, conference: true,
              patterns: [#"computer vision and pattern recognition workshops?"#, #"\bcvprw\b"#], doi: ["cvprw"]),
        Entry(abbreviation: "ICCV", name: "IEEE/CVF International Conference on Computer Vision", ccf: "A", conference: true,
              patterns: [#"international conference on computer vision(?! theory)"#, #"\biccv\b"#], doi: ["iccv"]),
        Entry(abbreviation: "ICCVW", name: "ICCV Workshops", ccf: nil, conference: true,
              patterns: [#"international conference on computer vision workshops?"#, #"\biccvw\b"#], doi: ["iccvw"]),
        Entry(abbreviation: "ECCV", name: "European Conference on Computer Vision", ccf: "B", conference: true,
              patterns: [#"european conference on computer vision"#, #"\beccv\b"#], doi: []),
        Entry(abbreviation: "WACV", name: "IEEE/CVF Winter Conference on Applications of Computer Vision", ccf: nil, conference: true,
              patterns: [#"winter conference on applications of computer vision"#, #"\bwacv\b"#], doi: ["wacv"]),
        Entry(abbreviation: "BMVC", name: "British Machine Vision Conference", ccf: "C", conference: true,
              patterns: [#"british machine vision conference"#, #"\bbmvc\b"#], doi: []),
        Entry(abbreviation: "ACCV", name: "Asian Conference on Computer Vision", ccf: "C", conference: true,
              patterns: [#"asian conference on computer vision"#, #"\baccv\b"#], doi: []),
        Entry(abbreviation: "3DV", name: "International Conference on 3D Vision", ccf: nil, conference: true,
              patterns: [#"international conference on 3d vision"#], doi: ["3dv"]),
        Entry(abbreviation: "TPAMI", name: "IEEE Transactions on Pattern Analysis and Machine Intelligence", ccf: "A", conference: false,
              patterns: [#"transactions on pattern analysis and machine intelligence"#, #"\btpami\b"#], doi: ["tpami"]),
        Entry(abbreviation: "IJCV", name: "International Journal of Computer Vision", ccf: "A", conference: false,
              patterns: [#"international journal of computer vision"#, #"\bijcv\b"#], doi: []),
        Entry(abbreviation: "TIP", name: "IEEE Transactions on Image Processing", ccf: "A", conference: false,
              patterns: [#"transactions on image processing"#], doi: ["tip"]),
        Entry(abbreviation: "TMM", name: "IEEE Transactions on Multimedia", ccf: "B", conference: false,
              patterns: [#"transactions on multimedia"#], doi: ["tmm"]),
        Entry(abbreviation: "TCSVT", name: "IEEE Transactions on Circuits and Systems for Video Technology", ccf: "B", conference: false,
              patterns: [#"transactions on circuits and systems for video technology"#], doi: ["tcsvt"]),
        Entry(abbreviation: "CVIU", name: "Computer Vision and Image Understanding", ccf: "B", conference: false,
              patterns: [#"computer vision and image understanding"#], doi: []),
        Entry(abbreviation: "PR", name: "Pattern Recognition", ccf: "B", conference: false,
              patterns: [#"^pattern recognition$"#], doi: []),
        Entry(abbreviation: "PRL", name: "Pattern Recognition Letters", ccf: "C", conference: false,
              patterns: [#"pattern recognition letters"#], doi: []),
        // Machine learning and AI
        Entry(abbreviation: "NeurIPS", name: "Advances in Neural Information Processing Systems", ccf: "A", conference: true,
              patterns: [#"neural information processing systems"#, #"\bneurips\b"#, #"\bnips\b"#], doi: []),
        Entry(abbreviation: "ICML", name: "International Conference on Machine Learning", ccf: "A", conference: true,
              patterns: [#"international conference on machine learning(?! and)"#, #"\bicml\b"#], doi: []),
        Entry(abbreviation: "ICLR", name: "International Conference on Learning Representations", ccf: nil, conference: true,
              patterns: [#"international conference on learning representations"#, #"\biclr\b"#], doi: []),
        Entry(abbreviation: "AAAI", name: "AAAI Conference on Artificial Intelligence", ccf: "A", conference: true,
              patterns: [#"\baaai\b"#], doi: []),
        Entry(abbreviation: "IJCAI", name: "International Joint Conference on Artificial Intelligence", ccf: "A", conference: true,
              patterns: [#"international joint conference on artificial intelligence"#, #"\bijcai\b"#], doi: []),
        Entry(abbreviation: "KDD", name: "ACM SIGKDD Conference on Knowledge Discovery and Data Mining", ccf: "A", conference: true,
              patterns: [#"knowledge discovery and data mining"#, #"\bkdd\b"#], doi: []),
        Entry(abbreviation: "ACM MM", name: "ACM International Conference on Multimedia", ccf: "A", conference: true,
              patterns: [#"acm international conference on multimedia"#, #"\bacm ?mm\b"#], doi: []),
        Entry(abbreviation: "TNNLS", name: "IEEE Transactions on Neural Networks and Learning Systems", ccf: "B", conference: false,
              patterns: [#"transactions on neural networks and learning systems"#], doi: ["tnnls"]),
        Entry(abbreviation: "JMLR", name: "Journal of Machine Learning Research", ccf: "A", conference: false,
              patterns: [#"journal of machine learning research"#, #"\bjmlr\b"#], doi: []),
        Entry(abbreviation: "TMLR", name: "Transactions on Machine Learning Research", ccf: nil, conference: false,
              patterns: [#"transactions on machine learning research"#], doi: []),
        Entry(abbreviation: "AIJ", name: "Artificial Intelligence", ccf: "A", conference: false,
              patterns: [#"^artificial intelligence$"#], doi: []),
        Entry(abbreviation: "TKDE", name: "IEEE Transactions on Knowledge and Data Engineering", ccf: "A", conference: false,
              patterns: [#"transactions on knowledge and data engineering"#], doi: ["tkde"]),
        Entry(abbreviation: "TCYB", name: "IEEE Transactions on Cybernetics", ccf: "B", conference: false,
              patterns: [#"transactions on cybernetics"#], doi: ["tcyb"]),
        Entry(abbreviation: "NN", name: "Neural Networks", ccf: "B", conference: false,
              patterns: [#"^neural networks$"#], doi: []),
        Entry(abbreviation: "Neurocomputing", name: "Neurocomputing", ccf: "C", conference: false,
              patterns: [#"^neurocomputing$"#], doi: []),
        // Language
        Entry(abbreviation: "ACL", name: "Annual Meeting of the Association for Computational Linguistics", ccf: "A", conference: true,
              patterns: [#"annual meeting of the association for computational linguistics"#, #"^acl\b"#], doi: []),
        Entry(abbreviation: "EMNLP", name: "Conference on Empirical Methods in Natural Language Processing", ccf: "B", conference: true,
              patterns: [#"empirical methods in natural language processing"#, #"\bemnlp\b"#], doi: []),
        Entry(abbreviation: "NAACL", name: "North American Chapter of the ACL", ccf: "B", conference: true,
              patterns: [#"north american chapter of the association for computational linguistics"#, #"\bnaacl\b"#], doi: []),
        // Medical imaging
        Entry(abbreviation: "MICCAI", name: "Medical Image Computing and Computer Assisted Intervention", ccf: "B", conference: true,
              patterns: [#"medical image computing and computer[- ]assisted intervention"#, #"\bmiccai\b"#], doi: []),
        Entry(abbreviation: "ISBI", name: "IEEE International Symposium on Biomedical Imaging", ccf: "C", conference: true,
              patterns: [#"international symposium on biomedical imaging"#, #"\bisbi\b"#], doi: ["isbi"]),
        Entry(abbreviation: "TMI", name: "IEEE Transactions on Medical Imaging", ccf: "B", conference: false,
              patterns: [#"transactions on medical imaging"#], doi: ["tmi"]),
        Entry(abbreviation: "MedIA", name: "Medical Image Analysis", ccf: "B", conference: false,
              patterns: [#"^medical image analysis$"#], doi: []),
        Entry(abbreviation: "JBHI", name: "IEEE Journal of Biomedical and Health Informatics", ccf: "C", conference: false,
              patterns: [#"journal of biomedical and health informatics"#], doi: ["jbhi"]),
        Entry(abbreviation: "TBME", name: "IEEE Transactions on Biomedical Engineering", ccf: nil, conference: false,
              patterns: [#"transactions on biomedical engineering"#], doi: ["tbme"]),
        Entry(abbreviation: "BSPC", name: "Biomedical Signal Processing and Control", ccf: nil, conference: false,
              patterns: [#"biomedical signal processing and control"#], doi: []),
        Entry(abbreviation: "CMIG", name: "Computerized Medical Imaging and Graphics", ccf: nil, conference: false,
              patterns: [#"computerized medical imaging and graphics"#], doi: []),
        Entry(abbreviation: "CIBM", name: "Computers in Biology and Medicine", ccf: nil, conference: false,
              patterns: [#"computers in biology and medicine"#], doi: []),
        // Remote sensing, robotics, graphics, signal processing
        Entry(abbreviation: "TGRS", name: "IEEE Transactions on Geoscience and Remote Sensing", ccf: nil, conference: false,
              patterns: [#"transactions on geoscience and remote sensing"#], doi: ["tgrs"]),
        Entry(abbreviation: "ISPRS", name: "ISPRS Journal of Photogrammetry and Remote Sensing", ccf: nil, conference: false,
              patterns: [#"isprs journal of photogrammetry and remote sensing"#], doi: []),
        Entry(abbreviation: "ICRA", name: "IEEE International Conference on Robotics and Automation", ccf: "B", conference: true,
              patterns: [#"international conference on robotics and automation"#, #"\bicra\b"#], doi: ["icra"]),
        Entry(abbreviation: "IROS", name: "IEEE/RSJ International Conference on Intelligent Robots and Systems", ccf: "C", conference: true,
              patterns: [#"intelligent robots and systems"#, #"\biros\b"#], doi: ["iros"]),
        Entry(abbreviation: "T-ITS", name: "IEEE Transactions on Intelligent Transportation Systems", ccf: "B", conference: false,
              patterns: [#"transactions on intelligent transportation systems"#], doi: ["tits"]),
        Entry(abbreviation: "SIGGRAPH", name: "ACM SIGGRAPH", ccf: "A", conference: true,
              patterns: [#"\bsiggraph\b(?! asia)"#], doi: []),
        Entry(abbreviation: "TOG", name: "ACM Transactions on Graphics", ccf: "A", conference: false,
              patterns: [#"acm transactions on graphics"#], doi: []),
        Entry(abbreviation: "TVCG", name: "IEEE Transactions on Visualization and Computer Graphics", ccf: "A", conference: false,
              patterns: [#"transactions on visualization and computer graphics"#], doi: ["tvcg"]),
        Entry(abbreviation: "ICASSP", name: "IEEE International Conference on Acoustics, Speech and Signal Processing", ccf: "B", conference: true,
              patterns: [#"acoustics,? speech,? and signal processing"#, #"\bicassp\b"#], doi: ["icassp"]),
        Entry(abbreviation: "ICIP", name: "IEEE International Conference on Image Processing", ccf: "C", conference: true,
              patterns: [#"international conference on image processing"#, #"\bicip\b"#], doi: ["icip"]),
        Entry(abbreviation: "ICME", name: "IEEE International Conference on Multimedia and Expo", ccf: "B", conference: true,
              patterns: [#"international conference on multimedia and expo"#, #"\bicme\b"#], doi: ["icme"]),
        Entry(abbreviation: "TSP", name: "IEEE Transactions on Signal Processing", ccf: "B", conference: false,
              patterns: [#"transactions on signal processing"#], doi: ["tsp"]),
        Entry(abbreviation: "SPL", name: "IEEE Signal Processing Letters", ccf: "C", conference: false,
              patterns: [#"signal processing letters"#], doi: ["lsp"]),
        Entry(abbreviation: "TIFS", name: "IEEE Transactions on Information Forensics and Security", ccf: "A", conference: false,
              patterns: [#"transactions on information forensics and security"#], doi: ["tifs"]),
        // General science
        Entry(abbreviation: "Nature", name: "Nature", ccf: nil, conference: false, patterns: [#"^nature$"#], doi: []),
        Entry(abbreviation: "Science", name: "Science", ccf: nil, conference: false, patterns: [#"^science$"#], doi: []),
        Entry(abbreviation: "Nat. Commun.", name: "Nature Communications", ccf: nil, conference: false,
              patterns: [#"^nature communications$"#], doi: []),
        Entry(abbreviation: "Nat. Mach. Intell.", name: "Nature Machine Intelligence", ccf: nil, conference: false,
              patterns: [#"^nature machine intelligence$"#], doi: []),
        Entry(abbreviation: "Nat. Methods", name: "Nature Methods", ccf: nil, conference: false,
              patterns: [#"^nature methods$"#], doi: []),
        Entry(abbreviation: "Sci. Adv.", name: "Science Advances", ccf: nil, conference: false,
              patterns: [#"^science advances$"#], doi: []),
        Entry(abbreviation: "PNAS", name: "Proceedings of the National Academy of Sciences", ccf: nil, conference: false,
              patterns: [#"proceedings of the national academy of sciences"#, #"\bpnas\b"#], doi: []),
        Entry(abbreviation: "Sci. Rep.", name: "Scientific Reports", ccf: nil, conference: false,
              patterns: [#"^scientific reports$"#], doi: []),
        Entry(abbreviation: "IEEE Access", name: "IEEE Access", ccf: nil, conference: false,
              patterns: [#"^ieee access$"#], doi: ["access"]),
    ]

    private static let compiled: [(Entry, [NSRegularExpression])] = entries.map { entry in
        (entry, entry.patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) })
    }

    /// Preprint servers: shown as they are.
    private static let preprints: [String: String] = [
        "arxiv": "arXiv", "arxiv.org": "arXiv", "biorxiv": "bioRxiv", "medrxiv": "medRxiv", "ssrn": "SSRN",
        "openreview": "OpenReview", "openreview.net": "OpenReview", "techrxiv": "TechRxiv", "research square": "Research Square",
    ]

    /// Words left out of an acronym.
    private static let minor: Set<String> = ["of", "and", "the", "on", "in", "for", "to", "a", "an", "&", "at", "with", "de", "la", "und", "fur", "für"]

    /// The venue of an item, or nil when it has none (a standalone file, no 来源).
    public static func venue(of item: Item) -> Venue? {
        guard item.kind == .regular else { return nil }
        return venue(source: item.source, doi: item.doi)
    }

    public static func venue(source rawSource: String?, doi: String?) -> Venue? {
        let source = (rawSource ?? "").replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lower = source.lowercased()
        if let preprint = preprints[lower.trimmingCharacters(in: CharacterSet(charactersIn: ". "))] {
            return Venue(abbreviation: preprint, fullName: nil, ccf: nil, isConference: false)
        }
        if !source.isEmpty {
            let range = NSRange(location: 0, length: (source as NSString).length)
            // Workshops first: "CVPR Workshops" also matches CVPR.
            let ordered = compiled.sorted { $0.0.abbreviation.hasSuffix("W") && !$1.0.abbreviation.hasSuffix("W") }
            for (entry, regexes) in ordered where regexes.contains(where: { $0.firstMatch(in: source, range: range) != nil }) {
                return Venue(abbreviation: entry.abbreviation, fullName: entry.name, ccf: entry.ccf, isConference: entry.conference)
            }
        }
        // The DOI's venue part: 10.1109/CVPR52729.2023.00987, 10.1109/TPAMI.2023.123.
        if let doi = doi?.lowercased(), let match = doi.firstMatch(of: /^10\.1109\/([a-z\-]+)\d*\./) {
            let code = String(match.1)
            if let entry = entries.first(where: { $0.doi.contains(code) }) {
                return Venue(abbreviation: entry.abbreviation, fullName: entry.name, ccf: entry.ccf, isConference: entry.conference)
            }
        }
        guard !source.isEmpty else { return nil }
        // An acronym the source itself gives: "… Conference (ICONIP)", "… 2023 (MICCAI 2023)".
        if let match = source.firstMatch(of: /\(([A-Z][A-Za-z0-9\-]{1,11})(?:'?\s?\d{2,4})?\)/) {
            let acronym = String(match.1)
            if acronym.filter(\.isUppercase).count >= 2 {
                return Venue(abbreviation: acronym, fullName: source, ccf: nil, isConference: lower.contains("conference") || lower.contains("proceedings"))
            }
        }
        // Short names stay as they are ("Array", "Remote Sensing").
        let words = source.split(separator: " ").map(String.init)
        if source.count <= 18 || words.count <= 2 {
            return Venue(abbreviation: source, fullName: nil, ccf: nil, isConference: false)
        }
        // Otherwise the initials of its main words, IEEE Transactions → "T": "IEEE Transactions on Neural … Systems" → TNNLS.
        var body = words
        if body.first?.uppercased() == "IEEE" || body.first?.uppercased() == "ACM" { body.removeFirst() }
        if body.first?.lowercased() == "proceedings", let of = body.firstIndex(where: { $0.lowercased() == "of" }), of < 3 {
            body.removeFirst(of + 1)
        }
        body.removeAll { $0.range(of: #"^\d{4}$|^\d+(st|nd|rd|th)$"#, options: [.regularExpression, .caseInsensitive]) != nil }
        let initials = body.filter { !minor.contains($0.lowercased()) }
            .compactMap { word -> Character? in
                let letters = word.trimmingCharacters(in: .punctuationCharacters)
                if letters.lowercased() == "transactions" { return "T" }
                return letters.first(where: \.isLetter).map { Character($0.uppercased()) }
            }
        guard initials.count >= 2 else { return Venue(abbreviation: source, fullName: nil, ccf: nil, isConference: false) }
        return Venue(abbreviation: String(initials.prefix(8)), fullName: source, ccf: nil,
                     isConference: lower.contains("conference") || lower.contains("proceedings") || lower.contains("symposium"))
    }
}
