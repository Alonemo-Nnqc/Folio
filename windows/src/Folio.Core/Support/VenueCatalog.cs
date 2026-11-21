using System.Globalization;
using System.Text.RegularExpressions;

namespace Folio.Core;

/// <summary>The short name of where a paper appeared ("CVPR", "TPAMI", "Nature") and, for venues known to everyone in the
/// field, their CCF class, recognised from the item's own metadata: the venue's full name in 来源, an acronym in it
/// ("… (ICCV)"), or the DOI's venue part (10.1109/CVPR…). Nothing is fetched; venues not in the list get an acronym of
/// their name when it is long enough to need one. (The macOS VenueCatalog.)</summary>
public static partial class VenueCatalog
{
    /// <param name="Abbreviation">The short name shown in the list.</param>
    /// <param name="FullName">The full name the abbreviation stands for (tooltip), when known.</param>
    /// <param name="Ccf">CCF class ("A", "B", "C") from the built-in list, when the venue is in it.</param>
    /// <param name="IsConference">True for conferences and workshops.</param>
    public sealed record Venue(string Abbreviation, string? FullName, string? Ccf, bool IsConference);

    sealed record Entry(string Abbreviation, string Name, string? Ccf, bool Conference, string[] Patterns, string[] Doi)
    {
        public readonly Regex[] Regexes = Patterns.Select(p => new Regex(p, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)).ToArray();
    }

    /// <summary>Well-known venues: (short name, full name, CCF class, conference?, name patterns, DOI venue codes).</summary>
    static readonly Entry[] Entries =
    [
        // Computer vision
        new("CVPR", "IEEE/CVF Conference on Computer Vision and Pattern Recognition", "A", true, [@"computer vision and pattern recognition", @"\bcvpr\b"], ["cvpr"]),
        new("CVPRW", "CVPR Workshops", null, true, [@"computer vision and pattern recognition workshops?", @"\bcvprw\b"], ["cvprw"]),
        new("ICCV", "IEEE/CVF International Conference on Computer Vision", "A", true, [@"international conference on computer vision(?! theory)", @"\biccv\b"], ["iccv"]),
        new("ICCVW", "ICCV Workshops", null, true, [@"international conference on computer vision workshops?", @"\biccvw\b"], ["iccvw"]),
        new("ECCV", "European Conference on Computer Vision", "B", true, [@"european conference on computer vision", @"\beccv\b"], []),
        new("WACV", "IEEE/CVF Winter Conference on Applications of Computer Vision", null, true, [@"winter conference on applications of computer vision", @"\bwacv\b"], ["wacv"]),
        new("BMVC", "British Machine Vision Conference", "C", true, [@"british machine vision conference", @"\bbmvc\b"], []),
        new("ACCV", "Asian Conference on Computer Vision", "C", true, [@"asian conference on computer vision", @"\baccv\b"], []),
        new("3DV", "International Conference on 3D Vision", null, true, [@"international conference on 3d vision"], ["3dv"]),
        new("TPAMI", "IEEE Transactions on Pattern Analysis and Machine Intelligence", "A", false, [@"transactions on pattern analysis and machine intelligence", @"\btpami\b"], ["tpami"]),
        new("IJCV", "International Journal of Computer Vision", "A", false, [@"international journal of computer vision", @"\bijcv\b"], []),
        new("TIP", "IEEE Transactions on Image Processing", "A", false, [@"transactions on image processing"], ["tip"]),
        new("TMM", "IEEE Transactions on Multimedia", "B", false, [@"transactions on multimedia"], ["tmm"]),
        new("TCSVT", "IEEE Transactions on Circuits and Systems for Video Technology", "B", false, [@"transactions on circuits and systems for video technology"], ["tcsvt"]),
        new("CVIU", "Computer Vision and Image Understanding", "B", false, [@"computer vision and image understanding"], []),
        new("PR", "Pattern Recognition", "B", false, [@"^pattern recognition$"], []),
        new("PRL", "Pattern Recognition Letters", "C", false, [@"pattern recognition letters"], []),
        // Machine learning and AI
        new("NeurIPS", "Advances in Neural Information Processing Systems", "A", true, [@"neural information processing systems", @"\bneurips\b", @"\bnips\b"], []),
        new("ICML", "International Conference on Machine Learning", "A", true, [@"international conference on machine learning(?! and)", @"\bicml\b"], []),
        new("ICLR", "International Conference on Learning Representations", null, true, [@"international conference on learning representations", @"\biclr\b"], []),
        new("AAAI", "AAAI Conference on Artificial Intelligence", "A", true, [@"\baaai\b"], []),
        new("IJCAI", "International Joint Conference on Artificial Intelligence", "A", true, [@"international joint conference on artificial intelligence", @"\bijcai\b"], []),
        new("KDD", "ACM SIGKDD Conference on Knowledge Discovery and Data Mining", "A", true, [@"knowledge discovery and data mining", @"\bkdd\b"], []),
        new("ACM MM", "ACM International Conference on Multimedia", "A", true, [@"acm international conference on multimedia", @"\bacm ?mm\b"], []),
        new("TNNLS", "IEEE Transactions on Neural Networks and Learning Systems", "B", false, [@"transactions on neural networks and learning systems"], ["tnnls"]),
        new("JMLR", "Journal of Machine Learning Research", "A", false, [@"journal of machine learning research", @"\bjmlr\b"], []),
        new("TMLR", "Transactions on Machine Learning Research", null, false, [@"transactions on machine learning research"], []),
        new("AIJ", "Artificial Intelligence", "A", false, [@"^artificial intelligence$"], []),
        new("TKDE", "IEEE Transactions on Knowledge and Data Engineering", "A", false, [@"transactions on knowledge and data engineering"], ["tkde"]),
        new("TCYB", "IEEE Transactions on Cybernetics", "B", false, [@"transactions on cybernetics"], ["tcyb"]),
        new("NN", "Neural Networks", "B", false, [@"^neural networks$"], []),
        new("Neurocomputing", "Neurocomputing", "C", false, [@"^neurocomputing$"], []),
        // Language
        new("ACL", "Annual Meeting of the Association for Computational Linguistics", "A", true, [@"annual meeting of the association for computational linguistics", @"^acl\b"], []),
        new("EMNLP", "Conference on Empirical Methods in Natural Language Processing", "B", true, [@"empirical methods in natural language processing", @"\bemnlp\b"], []),
        new("NAACL", "North American Chapter of the ACL", "B", true, [@"north american chapter of the association for computational linguistics", @"\bnaacl\b"], []),
        // Medical imaging
        new("MICCAI", "Medical Image Computing and Computer Assisted Intervention", "B", true, [@"medical image computing and computer[- ]assisted intervention", @"\bmiccai\b"], []),
        new("ISBI", "IEEE International Symposium on Biomedical Imaging", "C", true, [@"international symposium on biomedical imaging", @"\bisbi\b"], ["isbi"]),
        new("TMI", "IEEE Transactions on Medical Imaging", "B", false, [@"transactions on medical imaging"], ["tmi"]),
        new("MedIA", "Medical Image Analysis", "B", false, [@"^medical image analysis$"], []),
        new("JBHI", "IEEE Journal of Biomedical and Health Informatics", "C", false, [@"journal of biomedical and health informatics"], ["jbhi"]),
        new("TBME", "IEEE Transactions on Biomedical Engineering", null, false, [@"transactions on biomedical engineering"], ["tbme"]),
        new("BSPC", "Biomedical Signal Processing and Control", null, false, [@"biomedical signal processing and control"], []),
        new("CMIG", "Computerized Medical Imaging and Graphics", null, false, [@"computerized medical imaging and graphics"], []),
        new("CIBM", "Computers in Biology and Medicine", null, false, [@"computers in biology and medicine"], []),
        // Remote sensing, robotics, graphics, signal processing
        new("TGRS", "IEEE Transactions on Geoscience and Remote Sensing", null, false, [@"transactions on geoscience and remote sensing"], ["tgrs"]),
        new("ISPRS", "ISPRS Journal of Photogrammetry and Remote Sensing", null, false, [@"isprs journal of photogrammetry and remote sensing"], []),
        new("ICRA", "IEEE International Conference on Robotics and Automation", "B", true, [@"international conference on robotics and automation", @"\bicra\b"], ["icra"]),
        new("IROS", "IEEE/RSJ International Conference on Intelligent Robots and Systems", "C", true, [@"intelligent robots and systems", @"\biros\b"], ["iros"]),
        new("T-ITS", "IEEE Transactions on Intelligent Transportation Systems", "B", false, [@"transactions on intelligent transportation systems"], ["tits"]),
        new("SIGGRAPH", "ACM SIGGRAPH", "A", true, [@"\bsiggraph\b(?! asia)"], []),
        new("TOG", "ACM Transactions on Graphics", "A", false, [@"acm transactions on graphics"], []),
        new("TVCG", "IEEE Transactions on Visualization and Computer Graphics", "A", false, [@"transactions on visualization and computer graphics"], ["tvcg"]),
        new("ICASSP", "IEEE International Conference on Acoustics, Speech and Signal Processing", "B", true, [@"acoustics,? speech,? and signal processing", @"\bicassp\b"], ["icassp"]),
        new("ICIP", "IEEE International Conference on Image Processing", "C", true, [@"international conference on image processing", @"\bicip\b"], ["icip"]),
        new("ICME", "IEEE International Conference on Multimedia and Expo", "B", true, [@"international conference on multimedia and expo", @"\bicme\b"], ["icme"]),
        new("TSP", "IEEE Transactions on Signal Processing", "B", false, [@"transactions on signal processing"], ["tsp"]),
        new("SPL", "IEEE Signal Processing Letters", "C", false, [@"signal processing letters"], ["lsp"]),
        new("TIFS", "IEEE Transactions on Information Forensics and Security", "A", false, [@"transactions on information forensics and security"], ["tifs"]),
        // General science
        new("Nature", "Nature", null, false, [@"^nature$"], []),
        new("Science", "Science", null, false, [@"^science$"], []),
        new("Nat. Commun.", "Nature Communications", null, false, [@"^nature communications$"], []),
        new("Nat. Mach. Intell.", "Nature Machine Intelligence", null, false, [@"^nature machine intelligence$"], []),
        new("Nat. Methods", "Nature Methods", null, false, [@"^nature methods$"], []),
        new("Sci. Adv.", "Science Advances", null, false, [@"^science advances$"], []),
        new("PNAS", "Proceedings of the National Academy of Sciences", null, false, [@"proceedings of the national academy of sciences", @"\bpnas\b"], []),
        new("Sci. Rep.", "Scientific Reports", null, false, [@"^scientific reports$"], []),
        new("IEEE Access", "IEEE Access", null, false, [@"^ieee access$"], ["access"]),
    ];

    /// <summary>Workshops first: "CVPR Workshops" also matches CVPR.</summary>
    static readonly Entry[] Ordered = Entries.Where(e => e.Abbreviation.EndsWith('W')).Concat(Entries.Where(e => !e.Abbreviation.EndsWith('W'))).ToArray();

    /// <summary>Preprint servers: shown as they are.</summary>
    static readonly Dictionary<string, string> Preprints = new()
    {
        ["arxiv"] = "arXiv", ["arxiv.org"] = "arXiv", ["biorxiv"] = "bioRxiv", ["medrxiv"] = "medRxiv", ["ssrn"] = "SSRN",
        ["openreview"] = "OpenReview", ["openreview.net"] = "OpenReview", ["techrxiv"] = "TechRxiv", ["research square"] = "Research Square",
    };

    /// <summary>Words left out of an acronym.</summary>
    static readonly HashSet<string> Minor = ["of", "and", "the", "on", "in", "for", "to", "a", "an", "&", "at", "with", "de", "la", "und", "fur", "für"];

    [GeneratedRegex(@"^10\.1109/([a-z\-]+)\d*\.")]
    private static partial Regex IeeeDoi();
    [GeneratedRegex(@"\(([A-Z][A-Za-z0-9\-]{1,11})(?:'?\s?\d{2,4})?\)")]
    private static partial Regex GivenAcronym();
    [GeneratedRegex(@"^\d{4}$|^\d+(st|nd|rd|th)$", RegexOptions.IgnoreCase)]
    private static partial Regex YearOrOrdinal();

    static string TrimPunctuation(string word)
    {
        int start = 0, end = word.Length;
        while (start < end && char.IsPunctuation(word[start])) start++;
        while (end > start && char.IsPunctuation(word[end - 1])) end--;
        return word[start..end];
    }

    /// <summary>The venue of an item, or null when it has none (a standalone file, no 来源).</summary>
    public static Venue? Of(Item item) => item.Kind == ItemKind.Regular ? Of(item.Source, item.Doi) : null;

    public static Venue? Of(string? rawSource, string? doi)
    {
        var source = string.Join(' ', Regex.Replace(rawSource ?? "", "&amp;", "&", RegexOptions.IgnoreCase).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var lower = source.ToLowerInvariant();
        if (Preprints.TryGetValue(lower.Trim('.', ' '), out var preprint)) return new Venue(preprint, null, null, false);
        if (source.Length > 0)
            foreach (var entry in Ordered)
                if (entry.Regexes.Any(r => r.IsMatch(source))) return new Venue(entry.Abbreviation, entry.Name, entry.Ccf, entry.Conference);
        // The DOI's venue part: 10.1109/CVPR52729.2023.00987, 10.1109/TPAMI.2023.123.
        if (doi?.ToLowerInvariant() is { } d && IeeeDoi().Match(d) is { Success: true } m)
        {
            var code = m.Groups[1].Value;
            if (Entries.FirstOrDefault(e => e.Doi.Contains(code)) is { } entry) return new Venue(entry.Abbreviation, entry.Name, entry.Ccf, entry.Conference);
        }
        if (source.Length == 0) return null;
        // An acronym the source itself gives: "… Conference (ICONIP)", "… 2023 (MICCAI 2023)".
        if (GivenAcronym().Match(source) is { Success: true } given)
        {
            var acronym = given.Groups[1].Value;
            if (acronym.Count(char.IsUpper) >= 2)
                return new Venue(acronym, source, null, lower.Contains("conference") || lower.Contains("proceedings"));
        }
        // Short names stay as they are ("Array", "Remote Sensing").
        var words = source.Split(' ').ToList();
        if (new StringInfo(source).LengthInTextElements <= 18 || words.Count <= 2) return new Venue(source, null, null, false);
        // Otherwise the initials of its main words, IEEE Transactions → "T": "IEEE Transactions on Neural … Systems" → TNNLS.
        var body = words;
        if (body[0].ToUpperInvariant() is "IEEE" or "ACM") body.RemoveAt(0);
        if (body.Count > 0 && body[0].ToLowerInvariant() == "proceedings")
        {
            int of = body.FindIndex(w => w.ToLowerInvariant() == "of");
            if (of >= 0 && of < 3) body.RemoveRange(0, of + 1);
        }
        body.RemoveAll(w => YearOrOrdinal().IsMatch(w));
        var initials = body.Where(w => !Minor.Contains(w.ToLowerInvariant())).Select(word =>
        {
            var letters = TrimPunctuation(word);
            if (letters.ToLowerInvariant() == "transactions") return "T";
            var first = letters.FirstOrDefault(char.IsLetter);
            return first == default ? null : char.ToUpperInvariant(first).ToString();
        }).Where(c => c != null).ToList();
        if (initials.Count < 2) return new Venue(source, null, null, false);
        return new Venue(string.Concat(initials.Take(8)), source, null,
                         lower.Contains("conference") || lower.Contains("proceedings") || lower.Contains("symposium"));
    }
}
