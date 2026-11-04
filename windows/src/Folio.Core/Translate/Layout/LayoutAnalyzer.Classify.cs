using System.Text.RegularExpressions;

namespace Folio.Core.Translate.Layout;

public sealed partial class LayoutAnalyzer
{
    bool IsHeadingLike(LayoutLine line)
    {
        var text = line.Text.Trim();
        if (line.WordCount > 14 || text.Length == 0) return false;
        if (text.EndsWith(',') || text.EndsWith('-')) return false;
        bool numbered = Regex.IsMatch(text, @"^((\d{1,2}(\.\d+)*\.?)|([IVX]+\.)|([A-Z]\.))\s+\p{Lu}");
        if (numbered && Regex.IsMatch(text, @"^[A-Z]\.\s") && (text.Contains(',') || text.Contains('“'))) numbered = false;
        bool bold = line.Font.IsBold;
        bool large = line.Size >= BodySize * 1.12;
        if (bold && !large && line.Chars.LastOrDefault(c => !c.IsSpace) is { } end && !end.Font.IsBold && !end.IsMath) return false;
        if (numbered && (bold || large || line.WordCount <= 8)) return true;
        return (bold || large) && line.Chars.Count(c => !c.IsSpace && c.Font.IsBold == bold) * 10 >= line.VisibleCount * 8;
    }

    public static bool IsCaptionStart(string text) =>
        Regex.IsMatch(text, @"^\s*(Figure|Fig\.?|FIGURE|FIG\.?|Table|TABLE|Tab\.|Algorithm|Listing|Scheme|Chart|Supplementary (Figure|Table)|图|表)\s*(S?\d+|[IVXLC]+\b)(\s*$|\s*[.:：|—–\-]|\s+[\p{Lu}\p{IsCJKUnifiedIdeographs}])");

    /// <summary>"• …", "– …", "1) …", "(ii) …", "[3] …" at the start of a line.</summary>
    public static bool IsListItem(string text) =>
        Regex.IsMatch(text, @"^\s*([•▪◦●○■□‣∙·\-–—*�]|\(?[0-9]{1,2}[.)]|\([ivxIVX]{1,4}\)|\([a-z]\)|\[\d{1,3}\])\s");

    public static bool IsAlgorithmStart(string text) => Regex.IsMatch(text, @"^\s*(Algorithm|ALGORITHM|Procedure|Pseudocode|算法)\s*\d*");

    /// <summary>Cell text worth translating: not an abbreviation, not mostly numbers.</summary>
    public static bool IsCellText(string raw)
    {
        var text = Regex.Replace(raw, @"\([^()]*(et al|\d{4})[^()]*\)", " ");
        text = Regex.Replace(text, @"\[[\d,\s–\-]+\]", " ");
        bool cited = text != raw;
        text = text.Trim();
        var tokens = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (cited && tokens.Length <= 3) return false;
        if (tokens.Length == 1 && Regex.IsMatch(text, @"^[A-Z0-9][A-Za-z0-9\-\.+/@%]{0,7}$") && (text.Count(char.IsUpper) >= 2 || text.Any(char.IsDigit))) return false;
        int numeric = tokens.Count(t => Regex.IsMatch(t, @"^[\d.,±%()\-–+*†‡]+$"));
        if (numeric * 2 >= tokens.Length) return false;
        return tokens.Any(token =>
        {
            var word = token.Trim(PunctuationChars);
            return Text.Graphemes(word) >= 3 && word.All(char.IsLetter) && word.Skip(1).All(char.IsLower);
        });
    }

    public static bool HasWords(string text) => Regex.IsMatch(text, @"\p{L}{2,}");

    void Classify(List<LayoutBlock> blocks, int page, Rect crop, List<Rect> boxes)
    {
        int? titleIndex = null;
        if (page == 1)
        {
            var candidates = Enumerable.Range(0, blocks.Count).Where(i =>
            {
                var rect = blocks[i].Rect;
                return rect.MinY > crop.MidY - crop.H * 0.1 && blocks[i].Size >= BodySize * 1.25 && TextWords(blocks[i].Lines[0]) >= 2
                       && !boxes.Any(b => b.InsetBy(-2, -2).Contains(rect));
            }).ToList();
            if (candidates.Count > 0) titleIndex = candidates.MaxBy(i => blocks[i].Size);
        }
        double? abstractTop = null;
        if (page == 1)
        {
            if (blocks.FirstOrDefault(b => IsAbstractStart(b.Text)) is { } @abstract) abstractTop = @abstract.Rect.MaxY;
            if (abstractTop == null && titleIndex is { } ti)
            {
                double titleBottom = blocks[ti].Rect.MinY;
                foreach (var block in blocks.Where(b => b.Rect.MaxY <= titleBottom + 1))
                {
                    bool isBody = block.Lines.Count >= 4 && block.Lines.Take(block.Lines.Count - 1).All(l => l.WordCount >= 6);
                    bool isFirstSection = Regex.IsMatch(block.Text, @"^\s*(1\.?|I\.)\s+\p{Lu}") && block.Lines.Count <= 2;
                    if (isBody || isFirstSection) abstractTop = Math.Max(abstractTop ?? 0, block.Rect.MaxY);
                }
            }
        }
        for (int i = 0; i < blocks.Count; i++)
        {
            var block = blocks[i];
            var text = block.Text.Trim();
            var first = block.Lines[0];
            if (i == titleIndex) { block.Kind = BlockKind.Title; continue; }
            if (IsCaptionStart(text)) { block.Kind = BlockKind.Caption; continue; }
            if (!_inReferences && !Opts.TranslateReferences && IsReferenceEntry(block))
            {
                block.Kind = BlockKind.Reference;
                block.Translate = false;
                continue;
            }
            if (!Opts.TranslateReferences && block.Lines.Count <= 2 && Regex.IsMatch(text, @"\b(vol\.|pp\.)\s*\d") && Regex.IsMatch(text, @"(19|20)\d\d"))
            {
                block.Kind = BlockKind.Reference;
                block.Translate = false;
                continue;
            }
            if (_inReferences && IsRunningProse(block)) _inReferences = false;
            if (!_inReferences && titleIndex is { } t && abstractTop is { } top && block.Rect.MinY > top && block.Rect.MaxY <= blocks[t].Rect.MinY + 1)
            {
                block.Kind = BlockKind.Author;
                block.Translate = false;
                continue;
            }
            bool heading = (block.Lines.Count <= 2 && block.Lines.All(l => IsHeadingLike(l) || (l.Font.IsBold && l.WordCount <= 10)))
                           || (block.Lines.Count == 1 && IsReferencesHeading(text));
            if (heading)
            {
                block.Kind = BlockKind.Heading;
                if (IsReferencesHeading(text))
                {
                    _inReferences = !Opts.TranslateReferences;
                    continue;
                }
                if (_inReferences && (EndsReferences(text) || IsNumberedSection(text))) _inReferences = false;
                if (_inReferences) { block.Kind = BlockKind.Reference; block.Translate = false; }
                continue;
            }
            if (_inReferences)
            {
                block.Kind = BlockKind.Reference;
                block.Translate = false;
                continue;
            }
            if (block.Font.IsMonospace && first.Font.IsMonospace)
            {
                block.Kind = BlockKind.Code;
                block.Translate = false;
                continue;
            }
            if (!HasWords(text))
            {
                block.Kind = BlockKind.Other;
                block.Translate = false;
            }
        }
        foreach (var block in blocks.Where(b => b.Translate))
        {
            int words = block.Lines.Sum(TextWords);
            bool mathHeavy = block.Lines.Sum(l => l.MathRatio) / block.Lines.Count > 0.3;
            var first = block.Lines[0].Chars.FirstOrDefault(c => !c.IsSpace);
            bool continues = first != null && !first.IsMath && StartsLower(first.Text);
            int needed = block.Kind == BlockKind.Paragraph && mathHeavy && !continues ? 2 : 1;
            var text = block.Text.Trim();
            bool url = Regex.IsMatch(text, @"^(https?://|www\.|doi:|arXiv:)\S+$", RegexOptions.IgnoreCase) || Regex.IsMatch(text, @"^\S+@\S+\.\S+$");
            if (url)
            {
                block.Kind = BlockKind.Other;
                block.Translate = false;
            }
            else if (words < needed && block.Kind != BlockKind.Title)
            {
                block.Kind = block.Kind == BlockKind.Paragraph ? BlockKind.Formula : BlockKind.Other;
                block.Translate = false;
            }
        }
    }

    static bool IsAbstractStart(string text) => Regex.IsMatch(text, @"^\s*(a\s?b\s?s\s?t\s?r\s?a\s?c\s?t|summary|摘\s*要)\b", RegexOptions.IgnoreCase);

    public static bool IsReferencesHeading(string text) =>
        Regex.IsMatch(text, @"^\s*((\d+|[IVX]+)\.?\s*)?(References|REFERENCES|Reference|Bibliography|BIBLIOGRAPHY|Literature Cited|Works Cited|参考文献)\s*$");

    static bool IsReferenceEntry(LayoutBlock block)
    {
        var text = block.Text;
        return block.Lines.Count <= 8 && Regex.IsMatch(text, @"^\s*\[\d{1,3}\]\s+\p{Lu}") && Regex.IsMatch(text, @"(19|20)\d\d") && text.Count(c => c == ',') >= 2;
    }

    static bool IsRunningProse(LayoutBlock block)
    {
        var text = block.Text;
        if (block.Lines.Count < 5 || text.Split(' ').Length < 50) return false;
        return !Regex.IsMatch(text, @"(19|20)\d\d|et al|\bpp\.|\bvol\.|\bProc\b|\bConf\b|\bJ\.|doi|arXiv|^\s*\[\d", RegexOptions.IgnoreCase);
    }

    static bool IsNumberedSection(string text) =>
        Regex.IsMatch(text, @"^\s*\d{1,2}(\.\d+)*\.?\s+\p{Lu}\p{Ll}") && !text.Contains(',') && text.Split(' ').Length <= 10;

    static bool EndsReferences(string text)
    {
        if (Regex.IsMatch(text, @"^\s*(Appendix|APPENDIX|Appendices|Supplementary|SUPPLEMENTARY|Supplemental|附录)")) return true;
        return Regex.IsMatch(text, @"^\s*[A-H](\.\d+)*\.?\s+\p{Lu}\p{Ll}") && !text.Contains(',') && !text.Contains('“') && !text.Contains('"')
               && !text.EndsWith('-') && text.Split(' ').Length <= 10;
    }
}
