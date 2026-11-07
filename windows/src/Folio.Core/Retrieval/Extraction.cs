using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;

namespace Folio.Core.Retrieval;

/// <summary>A persistent identifier that can be resolved directly.</summary>
public abstract record Identifier
{
    /// <summary>Lowercased, without resolver prefix.</summary>
    public sealed record Doi(string Value) : Identifier;
    /// <summary>Without version suffix.</summary>
    public sealed record Arxiv(string Value) : Identifier;
    /// <summary>Digits only (ISBN-10 may end in "X").</summary>
    public sealed record Isbn(string Value) : Identifier;

    /// <summary>Recognises DOIs, arXiv IDs and ISBNs, bare or in their usual URL / prefixed forms.</summary>
    public static Identifier? Parse(string s)
    {
        var raw = s.Trim();
        if (raw.Length == 0 || raw.Length > 500) return null;
        string text;
        try { text = Uri.UnescapeDataString(raw); } catch { text = raw; }
        if (IdentifierExtractor.Dois(text).FirstOrDefault() is { } doi) return new Doi(doi);
        if (IdentifierExtractor.ArxivIds(text, requireContext: true).FirstOrDefault() is { } arxiv) return new Arxiv(arxiv);
        if (IdentifierExtractor.Isbns(text, requireKeyword: false).FirstOrDefault() is { } isbn && IsbnOnly(text)) return new Isbn(isbn);
        if (IdentifierExtractor.IsBareArxivId(text))
        {
            var bare = Regex.Replace(text.Trim(), @"v\d+$", "");
            return new Arxiv(IdentifierExtractor.ArxivIds(text, requireContext: false).FirstOrDefault() ?? bare);
        }
        return null;
    }

    static bool IsbnOnly(string text)
    {
        var rest = text.ToLowerInvariant();
        foreach (var noise in new[] { "https://", "http://", "openlibrary.org/isbn/", "www.", "isbn-13", "isbn-10", "isbn", ".json", ":" })
            rest = rest.Replace(noise, "");
        return rest.All(c => char.IsDigit(c) || c is 'x' or '-' or ' ' or '/');
    }

    public override string ToString() => this switch { Doi d => d.Value, Arxiv a => "arXiv:" + a.Value, Isbn i => "ISBN " + i.Value, _ => "" };
}

enum IdentifierLocation { FirstPage, SecondPage, FileName, Metadata }

sealed record FoundIdentifier(Identifier Identifier, IdentifierLocation Location, bool IsSelfDescribing)
{
    public bool IsSelfDescribing { get; set; } = IsSelfDescribing;
    public bool IsArxiv => Identifier is Identifier.Arxiv;
    public bool IsIsbn => Identifier is Identifier.Isbn;
}

/// <summary>Finds DOIs, arXiv IDs and ISBNs in PDF text, file names and metadata.</summary>
static partial class IdentifierExtractor
{
    public static List<FoundIdentifier> Extract(PdfFacts facts)
    {
        var found = new List<FoundIdentifier>();
        void Add(Identifier identifier, IdentifierLocation location, bool self)
        {
            var existing = found.FirstOrDefault(f => f.Identifier == identifier);
            if (existing != null) existing.IsSelfDescribing |= self;
            else found.Add(new FoundIdentifier(identifier, location, self));
        }
        void Scan(string text, IdentifierLocation location, bool self)
        {
            if (text.Length == 0) return;
            var stamps = ArxivStampIds(text).ToHashSet();
            var hits = new List<(int Offset, Identifier Id, bool Self)>();
            foreach (Match m in DoiPattern().Matches(text))
                if (CleanDoi(m.Value) is { } doi) hits.Add((m.Index, new Identifier.Doi(doi), self));
            foreach (var (offset, id) in ArxivMatches(text, true)) hits.Add((offset, new Identifier.Arxiv(id), self || stamps.Contains(id)));
            foreach (var (offset, isbn) in IsbnMatches(text, true)) hits.Add((offset, new Identifier.Isbn(isbn), self));
            foreach (var hit in hits.OrderBy(h => h.Offset)) Add(hit.Id, location, hit.Self);
        }
        Scan(facts.FirstPageText, IdentifierLocation.FirstPage, false);
        Scan(facts.SecondPageText, IdentifierLocation.SecondPage, false);
        var name = Path.GetFileNameWithoutExtension(facts.FileName);
        foreach (var doi in FileNameDois(name)) Add(new Identifier.Doi(doi), IdentifierLocation.FileName, false);
        foreach (var id in ArxivIds(name, false)) Add(new Identifier.Arxiv(id), IdentifierLocation.FileName, false);
        Scan(facts.MetadataText, IdentifierLocation.Metadata, true);
        return found.OrderBy(f => f.Location).ToList();
    }

    [GeneratedRegex("""10\.\d{4,9}/[^\s"<>]+""")]
    private static partial Regex DoiPattern();

    public static List<string> Dois(string text) =>
        DoiPattern().Matches(text).Select(m => CleanDoi(m.Value)).Where(d => d != null).Distinct().ToList()!;

    /// <summary>Strips trailing punctuation that is not part of the DOI and lowercases it.</summary>
    public static string? CleanDoi(string raw)
    {
        var doi = raw;
        while (doi.Length > 0)
        {
            char last = doi[^1];
            if (".,;:'\"".Contains(last)) doi = doi[..^1];
            else if (last == ')' && doi.Count(c => c == '(') < doi.Count(c => c == ')')) doi = doi[..^1];
            else if (last == ']' && doi.Count(c => c == '[') < doi.Count(c => c == ']')) doi = doi[..^1];
            else break;
        }
        int slash = doi.IndexOf('/');
        if (slash < 0 || slash + 1 >= doi.Length) return null;
        return doi.ToLowerInvariant();
    }

    static List<string> FileNameDois(string name)
    {
        var direct = Dois(name);
        if (direct.Count > 0) return direct;
        var m = Regex.Match(name, @"10\.\d{4,9}_\S+");
        if (!m.Success) return [];
        var candidate = m.Value;
        int underscore = candidate.IndexOf('_');
        candidate = candidate[..underscore] + "/" + candidate[(underscore + 1)..];
        return CleanDoi(candidate) is { } d ? [d] : [];
    }

    /// <summary>"10.48550/arxiv.2405.02717" → "2405.02717".</summary>
    public static string? ArxivIdFromDoi(string doi)
    {
        const string prefix = "10.48550/arxiv.";
        if (!doi.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return null;
        return ArxivIds(doi[prefix.Length..], false).FirstOrDefault();
    }

    const string ModernId = @"(\d{4}\.\d{4,5})(?:v\d+)?";
    const string LegacyId = @"([a-z][a-z\-]*(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?";

    static readonly Regex[] Contextual =
    [
        new(@"(?i:arxiv)\s*[:.]?\s*" + ModernId + @"(?!\d)"),
        new(@"(?i:arxiv\.org/(?:abs|pdf)/)" + ModernId + @"(?!\d)"),
        new(@"(?i:arxiv)\s*:\s*" + LegacyId + @"(?!\d)"),
        new(@"(?i:arxiv\.org/(?:abs|pdf)/)" + LegacyId + @"(?!\d)"),
    ];
    static readonly Regex BareModern = new(@"(?<![\d.])" + ModernId + @"(?![\d])");
    static readonly Regex BarePattern = new(@"^(?:" + ModernId + "|" + LegacyId + ")$");
    static readonly Regex Stamp = new(@"arXiv:(\d{4}\.\d{4,5}|[a-z][a-z\-]*(?:\.[A-Z]{2})?/\d{7})v\d+\s*\[[A-Za-z.\-]+\]");

    public static List<string> ArxivIds(string text, bool requireContext) =>
        ArxivMatches(text, requireContext).Select(m => m.Id).Distinct().ToList();

    static List<string> ArxivStampIds(string text) =>
        Stamp.Matches(text).Select(m => m.Groups[1].Value).Where(IsPlausibleArxivId).Distinct().ToList();

    public static bool IsBareArxivId(string text) => BarePattern.IsMatch(text.Trim());

    static List<(int Offset, string Id)> ArxivMatches(string text, bool requireContext)
    {
        var patterns = requireContext ? Contextual : [BareModern];
        return patterns.SelectMany(p => p.Matches(text).Select(m => (m.Groups[1].Index, m.Groups[1].Value)))
            .Where(m => IsPlausibleArxivId(m.Value)).OrderBy(m => m.Index).Select(m => (m.Index, m.Value)).ToList();
    }

    /// <summary>Checks the YYMM prefix of modern IDs (4-digit numbers until 2014, 5-digit since 2015).</summary>
    static bool IsPlausibleArxivId(string id)
    {
        int dot = id.IndexOf('.');
        if (dot < 0 || id.Contains('/')) return id.Contains('/');
        var prefix = id[..dot];
        var number = id[(dot + 1)..];
        if (!int.TryParse(prefix, out var yymm) || !int.TryParse(prefix[^2..], out var month) || month is < 1 or > 12) return false;
        if (yymm / 100 < 7) return false;
        return number.Length == 4 ? yymm <= 1412 : yymm >= 1501;
    }

    static readonly Regex KeywordIsbn = new(@"ISBN(?:-1[03])?\s*:?\s*([0-9][0-9\-\s]{8,18}[0-9Xx])", RegexOptions.IgnoreCase);
    static readonly Regex BareIsbn = new(@"(?<![\dXx])((?:97[89][\-\s]?)?(?:\d[\-\s]?){9}[\dXx])(?![\dXx])");

    public static List<string> Isbns(string text, bool requireKeyword) => IsbnMatches(text, requireKeyword).Select(m => m.Isbn).Distinct().ToList();

    static List<(int Offset, string Isbn)> IsbnMatches(string text, bool requireKeyword)
    {
        var result = new List<(int, string)>();
        foreach (Match m in (requireKeyword ? KeywordIsbn : BareIsbn).Matches(text))
        {
            var compact = new string(m.Groups[1].Value.ToUpperInvariant().Where(c => char.IsDigit(c) || c == 'X').ToArray());
            foreach (var length in new[] { 13, 10 })
            {
                if (compact.Length < length) continue;
                var candidate = compact[..length];
                if (IsValidIsbn(candidate)) { result.Add((m.Groups[1].Index, candidate)); break; }
            }
        }
        return result;
    }

    public static bool IsValidIsbn(string isbn)
    {
        var chars = isbn.ToUpperInvariant();
        if (chars.Length == 10)
        {
            int sum = 0;
            for (int i = 0; i < 10; i++)
            {
                int value;
                if (char.IsDigit(chars[i])) value = chars[i] - '0';
                else if (chars[i] == 'X' && i == 9) value = 10;
                else return false;
                sum += value * (10 - i);
            }
            return sum % 11 == 0;
        }
        if (chars.Length == 13)
        {
            int sum = 0;
            for (int i = 0; i < 13; i++)
            {
                if (!char.IsDigit(chars[i])) return false;
                sum += (chars[i] - '0') * (i % 2 == 0 ? 1 : 3);
            }
            return sum % 10 == 0 && (isbn.StartsWith("978") || isbn.StartsWith("979"));
        }
        return false;
    }
}

/// <summary>One visual text line of a page with its dominant font.</summary>
sealed record TextLine(string Text, double FontSize, string FontName);

/// <summary>Everything the engine needs from a PDF, extracted once up front.</summary>
sealed class PdfFacts
{
    public string FileName { get; init; } = "";
    public string? EmbeddedTitle { get; set; }
    public string? EmbeddedAuthor { get; set; }
    /// <summary>Info Subject/Keywords plus the raw XMP packet; used for identifier extraction.</summary>
    public string MetadataText { get; set; } = "";
    public string FirstPageText { get; set; } = "";
    public string SecondPageText { get; set; } = "";
    public List<TextLine> FirstPageLines { get; set; } = [];
    public bool UsedOcr { get; set; }

    public static PdfFacts? Extract(string path)
    {
        try
        {
            using var document = PdfDocument.Open(path);
            var facts = new PdfFacts { FileName = Path.GetFileName(path) };
            var info = document.Information;
            facts.EmbeddedTitle = Text.NonEmpty(info.Title);
            facts.EmbeddedAuthor = Text.NonEmpty(info.Author);
            var parts = new List<string?> { Text.NonEmpty(info.Subject), Text.NonEmpty(info.Keywords) };
            if (document.TryGetXmpMetadata(out var xmp))
            {
                var bytes = xmp.GetXmlBytes().ToArray();
                parts.Add(Encoding.UTF8.GetString(bytes, 0, Math.Min(bytes.Length, 256 * 1024)));
            }
            facts.MetadataText = string.Join('\n', parts.Where(p => p != null));
            if (document.NumberOfPages >= 1)
            {
                var first = document.GetPage(1);
                facts.FirstPageLines = PdfLines.Lines(first);
                facts.FirstPageText = string.Join('\n', facts.FirstPageLines.Select(l => l.Text));
            }
            if (document.NumberOfPages > 1) facts.SecondPageText = PdfLines.PlainText(document.GetPage(2));
            return facts;
        }
        catch
        {
            return null;
        }
    }
}

/// <summary>Reading order lines and text from PdfPig letters (PDFKit's page.string / attributedString equivalent).</summary>
static class PdfLines
{
    /// <summary>Visual lines top to bottom, each with the font covering most of its characters.</summary>
    public static List<TextLine> Lines(Page page)
    {
        var result = new List<TextLine>();
        foreach (var line in GroupLines(page.Letters))
        {
            var text = LineText(line).Trim();
            if (text.Length == 0) continue;
            var dominant = line.GroupBy(l => (Size: Math.Round(l.PointSize * 10) / 10, Name: BaseFontName(l.FontName ?? "")))
                .Select(g => (g.Key, Weight: g.Count())).OrderByDescending(g => g.Weight).ThenByDescending(g => g.Key.Size).FirstOrDefault();
            result.Add(new TextLine(text, dominant.Key.Size, dominant.Key.Name ?? ""));
        }
        return result;
    }

    public static string PlainText(Page page) => string.Join('\n', GroupLines(page.Letters).Select(LineText));

    /// <summary>Letters grouped into lines: same baseline (within half the font size), ordered left to right.</summary>
    public static List<List<Letter>> GroupLines(IReadOnlyList<Letter> letters)
    {
        var lines = new List<List<Letter>>();
        List<Letter>? current = null;
        double baseline = double.NaN;
        foreach (var letter in letters)
        {
            if (string.IsNullOrEmpty(letter.Value)) continue;
            double y = letter.StartBaseLine.Y;
            double tolerance = Math.Max(1.5, letter.PointSize * 0.5);
            if (current == null || Math.Abs(y - baseline) > tolerance)
            {
                current = [];
                lines.Add(current);
                baseline = y;
            }
            current.Add(letter);
        }
        // Content streams are mostly in reading order; lines that share a baseline but were drawn apart are merged.
        var merged = new List<List<Letter>>();
        foreach (var line in lines)
        {
            var match = merged.LastOrDefault();
            if (match != null && Math.Abs(match[0].StartBaseLine.Y - line[0].StartBaseLine.Y) < 0.5 && line[0].StartBaseLine.X > match[^1].EndBaseLine.X)
                match.AddRange(line);
            else merged.Add(line);
        }
        return merged;
    }

    /// <summary>Joins a line's letters, inserting spaces where the gap is wider than a fifth of the font size.</summary>
    public static string LineText(List<Letter> line)
    {
        var sb = new StringBuilder();
        Letter? previous = null;
        foreach (var letter in line)
        {
            if (previous != null && letter.Value != " " && previous.Value != " ")
            {
                double gap = letter.StartBaseLine.X - previous.EndBaseLine.X;
                if (gap > Math.Max(previous.PointSize, 1) * 0.2) sb.Append(' ');
            }
            sb.Append(letter.Value);
            previous = letter;
        }
        return Regex.Replace(sb.ToString(), " {2,}", " ");
    }

    public static string BaseFontName(string name)
    {
        int plus = name.IndexOf('+');
        return plus == 6 ? name[(plus + 1)..] : name;
    }
}

/// <summary>PDF text for the full-text index and the AI tools.</summary>
public static class PdfText
{
    /// <summary>All text of the document, or null when it cannot be opened or has no text layer.</summary>
    public static string? FullText(string path, int maxPages = int.MaxValue)
    {
        try
        {
            using var document = PdfDocument.Open(path);
            var sb = new StringBuilder();
            for (int i = 1; i <= Math.Min(document.NumberOfPages, maxPages); i++)
            {
                sb.Append(PdfLines.PlainText(document.GetPage(i))).Append('\n');
            }
            var text = sb.ToString().Trim();
            return text.Length == 0 ? null : text;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Text of one page (1-based), or null.</summary>
    public static string? PageText(string path, int page)
    {
        try
        {
            using var document = PdfDocument.Open(path);
            return page >= 1 && page <= document.NumberOfPages ? PdfLines.PlainText(document.GetPage(page)) : null;
        }
        catch { return null; }
    }

    public static int PageCount(string path)
    {
        try { using var document = PdfDocument.Open(path); return document.NumberOfPages; }
        catch { return 0; }
    }
}

/// <summary>Guesses the paper title from the first page layout and the embedded document title.</summary>
static partial class TitleGuesser
{
    public static List<string> Guesses(PdfFacts facts, int limit = 3)
    {
        var pageTokens = TextMatcher.Tokens(facts.FirstPageText);
        var layoutGuesses = LayoutCandidates(facts.FirstPageLines).Select(b => b.Text).ToList();
        var result = new List<string>();
        if (facts.EmbeddedTitle is { } raw && Clean(raw) is var embedded && IsTrustworthyEmbeddedTitle(embedded))
        {
            if (pageTokens.Count == 0 || TextMatcher.WindowSimilarity(embedded, pageTokens) >= 0.9) result.Add(embedded);
            else layoutGuesses.Insert(Math.Min(1, layoutGuesses.Count), embedded);
        }
        foreach (var guess in layoutGuesses)
            if (!result.Any(r => TitleNormalizer.Similarity(r, guess) >= 0.95)) result.Add(guess);
        return result.Take(limit).ToList();
    }

    public sealed record Block(string Text, double FontSize, int Order);

    public static List<Block> LayoutCandidates(List<TextLine> lines)
    {
        var blocks = MergeBlocks(lines);
        var candidates = new List<Block>();
        for (int i = 0; i < blocks.Count; i++)
        {
            if (!IsPlausibleTitle(blocks[i].Text)) continue;
            var next = i + 1 < blocks.Count ? blocks[i + 1].Text.ToLowerInvariant() : "";
            var previous = i > 0 ? blocks[i - 1].Text.ToLowerInvariant() : "";
            if (next.StartsWith("journal homepage") || previous.Contains("contents lists available")) continue;
            candidates.Add(blocks[i]);
        }
        return candidates.OrderByDescending(b => b.FontSize).ThenBy(b => b.Order).ToList();
    }

    public static List<Block> MergeBlocks(List<TextLine> lines)
    {
        var blocks = new List<Block>();
        var current = new List<TextLine>();
        void Flush()
        {
            if (current.Count == 0) return;
            blocks.Add(new Block(JoinLines(current.Select(l => l.Text).ToList()), current[0].FontSize, blocks.Count));
            current.Clear();
        }
        foreach (var line in lines)
        {
            var text = line.Text.Trim();
            if (text.Length == 0) continue;
            if (current.Count > 0 && Math.Abs(current[^1].FontSize - line.FontSize) <= 0.25 && current[^1].FontName == line.FontName && current.Count < 4)
                current.Add(line);
            else
            {
                Flush();
                current.Add(line);
            }
        }
        Flush();
        return blocks;
    }

    static string JoinLines(List<string> lines)
    {
        var result = "";
        foreach (var line in lines)
        {
            if (result.Length == 0) result = line;
            else if (result.EndsWith('-') && line.Length > 0 && char.IsLetter(line[0]) && result.Length >= 2 && char.IsLetter(result[^2]))
                result = char.IsLower(line[0]) && !IsCompoundPrefix(result) ? result[..^1] + line : result + line;
            else result += " " + line;
        }
        return Text.CollapseWhitespace(result);
    }

    static bool IsCompoundPrefix(string text)
    {
        var fragment = text[..^1].Split(' ').LastOrDefault() ?? "";
        return fragment.Length >= 4 || fragment.Contains('-');
    }

    static readonly string[] BannedFragments =
    [
        "arxiv:", "@", "http://", "https://", "www.", "doi:", "doi.org", "©", "copyright",
        "journal homepage", "contents lists available", "open access version", "computer vision foundation",
        "identical to the accepted version", "ieee xplore", "transactions on", "journal of latex",
        "issn", "received:", "accepted:", "available online", "manuscript received", "submitted to",
        "preprint submitted", "licensed under", "creative commons", "all rights reserved",
        "full length article", "research article", "original article", "review article",
        "article info", "a r t i c l e", "a b s t r a c t", "abstract—", "abstract.", "index terms",
        "keywords:", "proceedings of", "conference on", "workshop on", "university", "institute",
        "department", "laboratory", "school of", "college of",
    ];

    [GeneratedRegex(@"\b(vol|no)\.\s*\d", RegexOptions.IgnoreCase)]
    private static partial Regex VolumePattern();

    public static bool IsPlausibleTitle(string text)
    {
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length is < 3 or > 45) return false;
        var visible = text.Where(c => !char.IsWhiteSpace(c)).ToList();
        if (visible.Count == 0 || (double)visible.Count(char.IsLetter) / visible.Count < 0.6) return false;
        if (Text.CjkRatio(text) > 0.2) return false;
        var lower = text.ToLowerInvariant();
        if (BannedFragments.Any(lower.Contains)) return false;
        return !VolumePattern().IsMatch(text);
    }

    public static string Clean(string title) => Text.CollapseWhitespace(title);

    [GeneratedRegex(@"^[A-Z]{2,8}[-_ ]?\d")]
    private static partial Regex ManuscriptCode();

    public static bool IsTrustworthyEmbeddedTitle(string title)
    {
        var lower = title.ToLowerInvariant();
        var words = title.Split(' ');
        if (words.Length < 3 || title.Length > 400) return false;
        if (lower.StartsWith("microsoft ") || lower.StartsWith("untitled")) return false;
        if (new[] { ".pdf", ".doc", ".docx", ".tex", ".dvi", ".indd", ".rtf", ".ps" }.Any(lower.Contains)) return false;
        if (title.Contains('_') && words.Length < 4) return false;
        if (lower.Contains("doi") || lower.Contains("http")) return false;
        if (ManuscriptCode().IsMatch(title)) return false;
        return Text.CjkRatio(title) <= 0.2 && title.Count(char.IsLetter) >= 10;
    }
}

/// <summary>Fuzzy "does this title appear in that page" matching on normalised tokens.</summary>
static class TextMatcher
{
    public static List<string> Tokens(string text) => TitleNormalizer.Normalize(text).Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();

    public static double WindowSimilarity(string title, List<string> pageTokens)
    {
        var titleTokens = Tokens(title);
        if (titleTokens.Count == 0 || pageTokens.Count == 0) return 0;
        var normalizedTitle = string.Join(' ', titleTokens);
        var titleCounts = new Dictionary<string, int>();
        foreach (var t in titleTokens) titleCounts[t] = titleCounts.GetValueOrDefault(t) + 1;
        var shortlisted = new List<(double Overlap, int Start, int Length)>();
        foreach (var length in new[] { titleTokens.Count - 1, titleTokens.Count, titleTokens.Count + 1 }.Where(l => l > 0).Distinct())
        {
            if (length > pageTokens.Count) continue;
            for (int start = 0; start <= pageTokens.Count - length; start++)
            {
                var remaining = new Dictionary<string, int>(titleCounts);
                int shared = 0;
                for (int k = start; k < start + length; k++)
                {
                    if (remaining.TryGetValue(pageTokens[k], out var count) && count > 0) { shared++; remaining[pageTokens[k]] = count - 1; }
                }
                double overlap = 2.0 * shared / (titleTokens.Count + length);
                if (overlap >= 0.5) shortlisted.Add((overlap, start, length));
            }
        }
        double best = 0;
        foreach (var w in shortlisted.OrderByDescending(w => w.Overlap).Take(6))
        {
            var text = string.Join(' ', pageTokens.Skip(w.Start).Take(w.Length));
            best = Math.Max(best, TitleNormalizer.Similarity(text, normalizedTitle));
            if (best >= 1) break;
        }
        return best;
    }

    public static bool ContainsName(string name, List<string> pageTokens)
    {
        var nameTokens = Tokens(name);
        if (nameTokens.Count == 0 || nameTokens.Count > pageTokens.Count) return false;
        if (nameTokens.Count == 1 && nameTokens[0].Length < 2) return false;
        for (int start = 0; start <= pageTokens.Count - nameTokens.Count; start++)
        {
            bool matched = true;
            for (int offset = 0; offset < nameTokens.Count; offset++)
            {
                var page = pageTokens[start + offset];
                var token = nameTokens[offset];
                if (page == token) continue;
                if (offset == nameTokens.Count - 1 && page.StartsWith(token, StringComparison.Ordinal) && page.Length - token.Length <= 2) continue;
                matched = false;
                break;
            }
            if (matched) return true;
        }
        return false;
    }
}

/// <summary>Field clean-up shared by all source clients.</summary>
static partial class FieldNormalizer
{
    public static string? CleanText(string? raw)
    {
        if (raw == null) return null;
        var text = raw;
        if (text.Contains('<')) text = Regex.Replace(text, "<[^>]{0,200}>", " ");
        if (text.Contains('&')) text = DecodeEntities(text);
        var collapsed = Text.CollapseWhitespace(text);
        var tightened = Regex.Replace(Regex.Replace(collapsed, @" ([,.;:!?)\]])", "$1"), @"([(\[]) ", "$1");
        return tightened.Length == 0 ? null : tightened;
    }

    public static string? CleanTitle(string? raw, bool dropTrailingPeriod = false)
    {
        var title = CleanText(raw);
        if (title == null) return null;
        if (dropTrailingPeriod && title.EndsWith('.') && !title.EndsWith("..")) title = title[..^1];
        return title.Length == 0 ? null : title;
    }

    public static string? CleanAbstract(string? raw)
    {
        var text = CleanText(raw);
        if (text == null) return null;
        foreach (var heading in new[] { "Abstract", "ABSTRACT", "Summary", "SUMMARY" })
        {
            if (!text.StartsWith(heading, StringComparison.Ordinal)) continue;
            text = new string(text[heading.Length..].SkipWhile(c => " :.—-".Contains(c)).ToArray());
            break;
        }
        return text.Length == 0 ? null : text;
    }

    public static string? NormalizeDoi(string? raw)
    {
        var doi = raw?.Trim();
        if (string.IsNullOrEmpty(doi)) return null;
        foreach (var prefix in new[] { "https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:" })
        {
            if (!doi.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
            doi = doi[prefix.Length..];
            break;
        }
        doi = doi.ToLowerInvariant();
        return doi.StartsWith("10.") && doi.Contains('/') ? doi : null;
    }

    public static string? NormalizePages(string? raw) =>
        CleanText(raw)?.Replace("–", "-").Replace("—", "-").Replace("--", "-");

    public static string? NonEmpty(string? raw) => Text.NonEmpty(raw);

    public static (int Year, string Date)? DateFromParts(IReadOnlyList<int> parts)
    {
        if (parts.Count == 0 || parts[0] is < 1000 or > 9999) return null;
        var date = parts[0].ToString(CultureInfo.InvariantCulture);
        if (parts.Count > 1 && parts[1] is >= 1 and <= 12)
        {
            date += $"-{parts[1]:00}";
            if (parts.Count > 2 && parts[2] is >= 1 and <= 31) date += $"-{parts[2]:00}";
        }
        return (parts[0], date);
    }

    public static (int Year, string Date)? DateFromString(string? raw)
    {
        var text = raw?.Trim();
        if (string.IsNullOrEmpty(text)) return null;
        var iso = Regex.Match(text, @"^\d{4}(-\d{2}(-\d{2})?)?");
        if (iso.Success) return DateFromParts(iso.Value.Split('-').Select(int.Parse).ToList());
        var year = Regex.Match(text, @"\b(1[5-9]|20)\d{2}\b");
        if (year.Success) return (int.Parse(year.Value), year.Value);
        return null;
    }

    static readonly (string, string)[] Entities =
    [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "),
        ("&ndash;", "–"), ("&mdash;", "—"),
    ];

    static string DecodeEntities(string text)
    {
        foreach (var (entity, replacement) in Entities) text = text.Replace(entity, replacement);
        if (!text.Contains("&#")) return text;
        return Regex.Replace(text, "&#(x?)([0-9A-Fa-f]{1,6});", m =>
        {
            bool hex = m.Groups[1].Length > 0;
            try
            {
                var value = Convert.ToInt32(m.Groups[2].Value, hex ? 16 : 10);
                return char.ConvertFromUtf32(value);
            }
            catch { return ""; }
        });
    }
}

/// <summary>Splits display names ("Andong Lu", "Lu, Andong", "Charette, Raoul de") into family/given.</summary>
static class NameParser
{
    static readonly HashSet<string> Particles = ["van", "von", "der", "den", "de", "del", "della", "di", "da", "du", "la", "le", "dos", "das", "ter", "ten"];
    static readonly HashSet<string> Suffixes = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"];

    public static Author? FromDisplayName(string raw)
    {
        var name = Regex.Replace(Text.CollapseWhitespace(raw), @"\s+\d{4}$", "");
        if (name.Length == 0) return null;
        int comma = name.IndexOf(',');
        if (comma >= 0)
        {
            var family = name[..comma].Trim();
            var given = name[(comma + 1)..].Trim();
            if (family.Length > 0 && !Suffixes.Contains(given.ToLowerInvariant())) return new Author(family, given);
        }
        var tokens = name.Split(' ').ToList();
        if (tokens.Count == 1)
        {
            var only = tokens[0];
            int len = Text.Graphemes(only);
            if (len is >= 2 and <= 4 && Text.CjkRatio(only) == 1)
                return new Author(Text.PrefixGraphemes(only, 1), only[Text.PrefixGraphemes(only, 1).Length..]);
            return new Author(only);
        }
        var suffix = "";
        if (tokens.Count > 2 && Suffixes.Contains(tokens[^1].ToLowerInvariant()))
        {
            suffix = " " + tokens[^1];
            tokens.RemoveAt(tokens.Count - 1);
        }
        int familyStart = tokens.Count - 1;
        while (familyStart > 1 && Particles.Contains(tokens[familyStart - 1])) familyStart--;
        return new Author(string.Join(' ', tokens.Skip(familyStart)) + suffix, string.Join(' ', tokens.Take(familyStart)));
    }

    public static Author? From(string? family, string? given, string? literal)
    {
        var f = Text.NonEmpty(family);
        var g = Text.NonEmpty(given);
        if (f != null) return new Author(f, g ?? "");
        if (Text.NonEmpty(literal) is { } l) return new Author(l);
        return g != null ? FromDisplayName(g) : null;
    }
}
