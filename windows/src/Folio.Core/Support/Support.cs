using System.Globalization;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Folio.Core;

/// <summary>Canonicalises titles so that trivially different spellings compare equal.</summary>
public static class TitleNormalizer
{
    /// <summary>Lowercases, strips diacritics and width, replaces punctuation with spaces and collapses whitespace.</summary>
    public static string Normalize(string text)
    {
        var folded = Text.Fold(text);
        var sb = new StringBuilder(folded.Length);
        foreach (var rune in folded.EnumerateRunes())
        {
            var cat = Rune.GetUnicodeCategory(rune);
            bool alnum = Rune.IsLetterOrDigit(rune) || cat is UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber
                         or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;
            if (alnum) sb.Append(rune.ToString()); else sb.Append(' ');
        }
        return string.Join(' ', sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    /// <summary>Similarity in 0...1: the larger of token Dice coefficient and normalised Levenshtein similarity.</summary>
    public static double Similarity(string a, string b)
    {
        var na = Normalize(a);
        var nb = Normalize(b);
        if (na.Length == 0 || nb.Length == 0) return 0;
        if (na == nb) return 1;
        return Math.Max(Dice(na, nb), LevenshteinSimilarity(na, nb));
    }

    static double Dice(string a, string b)
    {
        var ta = a.Split(' ');
        var tb = b.Split(' ');
        var counts = new Dictionary<string, int>();
        foreach (var t in tb) counts[t] = counts.GetValueOrDefault(t) + 1;
        int shared = 0;
        foreach (var t in ta)
        {
            if (counts.GetValueOrDefault(t) > 0) { shared++; counts[t]--; }
        }
        return 2.0 * shared / (ta.Length + tb.Length);
    }

    static double LevenshteinSimilarity(string a, string b)
    {
        int longest = Math.Max(a.Length, b.Length);
        if (longest > 600) return 0;
        var previous = new int[b.Length + 1];
        var current = new int[b.Length + 1];
        for (int j = 0; j <= b.Length; j++) previous[j] = j;
        for (int i = 1; i <= a.Length; i++)
        {
            current[0] = i;
            for (int j = 1; j <= b.Length; j++)
            {
                int cost = a[i - 1] == b[j - 1] ? 0 : 1;
                current[j] = Math.Min(Math.Min(previous[j] + 1, current[j - 1] + 1), previous[j - 1] + cost);
            }
            (previous, current) = (current, previous);
        }
        return 1 - (double)previous[b.Length] / longest;
    }
}

/// <summary>Text helpers standing in for Foundation's string folding.</summary>
public static class Text
{
    /// <summary>Case-, diacritic- and width-insensitive form (like Foundation's folding options).</summary>
    public static string Fold(string text)
    {
        var decomposed = text.Normalize(NormalizationForm.FormKD);
        var sb = new StringBuilder(decomposed.Length);
        foreach (var ch in decomposed)
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark) sb.Append(ch);
        return sb.ToString().Normalize(NormalizationForm.FormKC).ToLowerInvariant();
    }

    public static string? NonEmpty(string? s)
    {
        var t = s?.Trim();
        return string.IsNullOrEmpty(t) ? null : t;
    }

    public static string CollapseWhitespace(string s) =>
        string.Join(' ', s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    public static int LetterCount(string s) => s.Count(char.IsLetter);

    /// <summary>Share of CJK ideographs / kana / hangul among the letters of text.</summary>
    public static double CjkRatio(string text)
    {
        int letters = 0, cjk = 0;
        foreach (var r in text.EnumerateRunes())
        {
            if (!Rune.IsLetter(r)) continue;
            letters++;
            int v = r.Value;
            if (v is >= 0x3040 and <= 0x30FF or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF or >= 0xF900 and <= 0xFAFF)
                cjk++;
        }
        return letters == 0 ? 0 : (double)cjk / letters;
    }

    /// <summary>Character count as Swift counts it (grapheme clusters).</summary>
    public static int Graphemes(string s) => new StringInfo(s).LengthInTextElements;

    public static string PrefixGraphemes(string s, int n)
    {
        var info = new StringInfo(s);
        return info.LengthInTextElements <= n ? s : info.SubstringByTextElements(0, n);
    }
}

/// <summary>Latin transliteration of CJK, kana and hangul, generated from macOS's own (see Resources/latin.txt).</summary>
public static class Transliteration
{
    static readonly Lazy<Dictionary<int, string>> Table = new(() =>
    {
        var map = new Dictionary<int, string>(40000);
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("latin.txt")!;
        using var reader = new StreamReader(stream, Encoding.UTF8);
        while (reader.ReadLine() is { } line)
        {
            if (line.Length < 2 || line[0] == '#') continue;
            var rune = Rune.GetRuneAt(line, 0);
            map[rune.Value] = line[rune.Utf16SequenceLength..];
        }
        return map;
    });

    /// <summary>Lowercase a-z0-9 only, like the macOS citation-key slug.</summary>
    public static string AsciiSlug(string text)
    {
        var sb = new StringBuilder();
        foreach (var rune in text.EnumerateRunes())
        {
            if (Table.Value.TryGetValue(rune.Value, out var latin)) { sb.Append(latin); continue; }
            foreach (var ch in Text.Fold(rune.ToString()))
                if (ch is >= 'a' and <= 'z' or >= '0' and <= '9') sb.Append(ch);
        }
        return sb.ToString();
    }
}

/// <summary>Formats author lists for list columns and citations.</summary>
public static class AuthorFormatter
{
    /// <summary>"Zhang, Tengya"; organisations render as their name alone.</summary>
    public static string Full(Author author)
    {
        var family = author.Family.Trim();
        var given = author.Given.Trim();
        if (given.Length == 0) return family;
        if (family.Length == 0) return given;
        return $"{family}, {given}";
    }

    /// <summary>One author: "Zhang, Tengya"; two: "Lou, Meng &amp; Yu, Yizhou"; three or more: "Zhang, Tengya et al.".</summary>
    public static string ListDisplay(IReadOnlyList<Author> authors) => authors.Count switch
    {
        0 => "",
        1 => Full(authors[0]),
        2 => $"{Full(authors[0])} & {Full(authors[1])}",
        _ => $"{Full(authors[0])} et al.",
    };
}

/// <summary>Generates BibTeX citation keys such as zhang2026.</summary>
public static class CitationKeyGenerator
{
    static readonly HashSet<string> StopWords = ["a", "an", "the", "on", "of", "for", "in", "and", "to", "with"];

    public static string BaseKey(Metadata metadata)
    {
        string stem;
        var family = metadata.Authors.FirstOrDefault()?.Family;
        if (family != null && Transliteration.AsciiSlug(family).Length > 0)
            stem = Transliteration.AsciiSlug(family);
        else
        {
            var words = TitleNormalizer.Normalize(metadata.Title).Split(' ', StringSplitOptions.RemoveEmptyEntries);
            var first = words.FirstOrDefault(w => !StopWords.Contains(w));
            stem = first != null ? Transliteration.AsciiSlug(first) : "item";
        }
        return stem + (metadata.Year?.ToString(CultureInfo.InvariantCulture) ?? "");
    }

    public static string UniqueKey(string @base, ISet<string> existing)
    {
        if (!existing.Contains(@base)) return @base;
        var suffix = "";
        do suffix = NextSuffix(suffix); while (existing.Contains(@base + suffix));
        return @base + suffix;
    }

    /// <summary>"" → "a" … "z" → "aa" → "ab" …</summary>
    static string NextSuffix(string s)
    {
        var chars = s.ToCharArray();
        for (int i = chars.Length - 1; i >= 0; i--)
        {
            if (chars[i] != 'z') { chars[i]++; return new string(chars); }
            chars[i] = 'a';
        }
        return "a" + new string(chars);
    }
}

/// <summary>Decides whether two metadata records describe the same work.</summary>
public static class DuplicateMatcher
{
    public static bool IsSameWork(Metadata a, Metadata b)
    {
        var da = a.Doi?.ToLowerInvariant();
        var db = b.Doi?.ToLowerInvariant();
        if (!string.IsNullOrEmpty(da) && !string.IsNullOrEmpty(db)) return da == db;
        var xa = a.ArxivId?.ToLowerInvariant();
        var xb = b.ArxivId?.ToLowerInvariant();
        if (!string.IsNullOrEmpty(xa) && xa == xb) return true;
        var ta = TitleNormalizer.Normalize(a.Title);
        if (ta.Length == 0 || ta != TitleNormalizer.Normalize(b.Title) || a.Year != b.Year) return false;
        return FirstAuthorKey(a) == FirstAuthorKey(b);
    }

    static string FirstAuthorKey(Metadata m) => TitleNormalizer.Normalize(m.Authors.FirstOrDefault()?.Family ?? "");
}

public static class FileHasher
{
    public static string Sha256(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(stream));
    }
}

/// <summary>Builds library file names of the form Family_Year_Title.</summary>
public static partial class FileNamer
{
    public const int MaxTitleLength = 80;

    public static string BaseName(Metadata metadata)
    {
        var parts = new List<string>();
        if (metadata.Authors.FirstOrDefault()?.Family is { } family)
        {
            var clean = Sanitize(family);
            if (clean.Length > 0) parts.Add(clean);
        }
        if (metadata.Year is { } year) parts.Add(year.ToString(CultureInfo.InvariantCulture));
        var title = Truncate(Sanitize(metadata.Title), MaxTitleLength);
        if (title.Length > 0) parts.Add(title);
        return parts.Count == 0 ? "Untitled" : string.Join('_', parts);
    }

    /// <summary>What a translation adds to its paper's name: "（双语对照 · Google）".</summary>
    public static string TranslationSuffix(TranslationKind kind, string? translatedBy)
    {
        var what = FileLabel.KindName(kind).ToLowerInvariant();
        var by = translatedBy == null ? null : Sanitize(translatedBy);
        if (string.IsNullOrEmpty(by)) return Loc.S("（%@）", what);
        return Loc.S("（%@ · %@）", what, by);
    }

    /// <summary>The bracketed note at the end of a translation's name; null when the name has none.</summary>
    public static string? TranslationSuffix(string stem)
    {
        var m = SuffixPattern().Match(stem);
        return m.Success ? m.Value : null;
    }

    /// <summary>"DeepSeek · deepseek-chat" from "论文（简体中文译文 · DeepSeek · deepseek-chat）".</summary>
    public static string? TranslatedBy(string stem)
    {
        if (TranslationSuffix(stem) is not { } suffix) return null;
        var inner = suffix.Trim(' ', '（', '）', '(', ')');
        var parts = inner.Split(" · ");
        return parts.Length > 1 ? string.Join(" · ", parts.Skip(1)) : null;
    }

    [GeneratedRegex(@"\s?[（(][^（）()]+ · [^（）()]+[）)]$")]
    private static partial Regex SuffixPattern();

    /// <summary>Makes text safe for file names (the macOS rules, plus Windows' reserved names and trailing dots).</summary>
    public static string Sanitize(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var ch in text)
        {
            switch (ch)
            {
                case ':': sb.Append(" -"); break;
                case '/' or '\\': sb.Append('-'); break;
                case '?' or '*' or '"' or '<' or '>' or '|': break;
                default:
                    if (char.IsControl(ch) || ch is '\n' or '\r' or (char)0x2028 or (char)0x2029) sb.Append(' ');
                    else sb.Append(ch);
                    break;
            }
        }
        var collapsed = Text.CollapseWhitespace(sb.ToString()).Trim(' ', '.');
        if (Reserved().IsMatch(collapsed)) collapsed = "_" + collapsed;
        return collapsed;
    }

    [GeneratedRegex(@"^(CON|PRN|AUX|NUL|COM\d|LPT\d)(\..*)?$", RegexOptions.IgnoreCase)]
    private static partial Regex Reserved();

    internal static string Truncate(string text, int limit)
    {
        if (Text.Graphemes(text) <= limit) return text;
        var prefix = Text.PrefixGraphemes(text, limit);
        int space = prefix.LastIndexOf(' ');
        if (space > limit / 2) return prefix[..space].TrimEnd(' ', '-', ',', '.');
        return prefix;
    }
}

/// <summary>What Folio shows for a file under its paper: 原文, 双语对照 · Google, 译文 · DeepSeek · deepseek-chat.</summary>
public static class FileLabel
{
    public static string KindName(TranslationKind kind) => kind == TranslationKind.Mono ? Loc.S("译文") : Loc.S("双语对照");

    public static string Title(FileRecord file, IReadOnlyList<FileRecord> files, string? defaultFileId)
    {
        if (file.TranslationKind is { } kind)
            return string.IsNullOrEmpty(file.TranslatedBy) ? KindName(kind) : $"{KindName(kind)} · {file.TranslatedBy}";
        return IsOriginal(file, files, defaultFileId) ? Loc.S("原文") : file.FileName;
    }

    public static bool IsOriginal(FileRecord file, IReadOnlyList<FileRecord> files, string? defaultFileId)
    {
        if (!file.IsPdf) return false;
        if (files.Any(f => f.TranslationOf == file.Id)) return true;
        var pdfs = files.Where(f => f.IsPdf && f.TranslationKind == null).ToList();
        return pdfs.Count == 1 || file.Id == defaultFileId;
    }
}

/// <summary>Manages the flat Files/ folder inside the library root.</summary>
public sealed class FileStore(string root)
{
    public const string FolderName = "Files";
    public string Root { get; } = root;
    public string FilesDirectory => Path.Combine(Root, FolderName);

    public string PathFor(string relativePath) => Path.Combine(Root, relativePath.Replace('/', Path.DirectorySeparatorChar));

    public void Prepare() => Directory.CreateDirectory(FilesDirectory);

    public string CopyIn(string source, string baseName, string ext)
    {
        var relative = UniqueRelativePath(baseName, ext, null);
        File.Copy(source, PathFor(relative));
        return relative;
    }

    public string Rename(string relativePath, string baseName)
    {
        var ext = Path.GetExtension(relativePath).TrimStart('.');
        var target = UniqueRelativePath(baseName, ext, relativePath);
        if (target == relativePath) return relativePath;
        File.Move(PathFor(relativePath), PathFor(target));
        return target;
    }

    public void Delete(string relativePath)
    {
        try { File.Delete(PathFor(relativePath)); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    public string UniqueRelativePath(string baseName, string ext, string? current)
    {
        var @base = string.IsNullOrEmpty(baseName) ? "Untitled" : baseName;
        for (int index = 1; ; index++)
        {
            var name = index == 1 ? @base : $"{@base} {index}";
            var fileName = ext.Length == 0 ? name : $"{name}.{ext}";
            var relative = $"{FolderName}/{fileName}";
            if (string.Equals(relative, current, StringComparison.OrdinalIgnoreCase)) return current!;
            if (!File.Exists(PathFor(relative))) return relative;
        }
    }
}

/// <summary>Metadata search: every token must appear somewhere in the item's text.</summary>
public static class SearchMatcher
{
    public static string[] Tokens(string query) =>
        query.ToLowerInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);

    public static bool Matches(string[] tokens, string haystack) => tokens.All(haystack.Contains);

    public static string Haystack(Item item, IEnumerable<Tag> tags, IEnumerable<FileRecord> files, string? note)
    {
        var parts = new List<string> { item.Title };
        parts.AddRange(item.Authors.Select(a => $"{a.Given} {a.Family}"));
        parts.AddRange(new[] { item.Source, item.Year?.ToString(CultureInfo.InvariantCulture), item.Doi, item.ArxivId, item.Isbn,
                               item.Abstract, item.CitationKey, item.Publisher }.Where(p => p != null)!);
        parts.AddRange(tags.Select(t => t.Name));
        parts.AddRange(files.SelectMany(f => new[] { f.FileName, f.OriginalName }));
        if (note != null) parts.Add(note);
        return string.Join('\n', parts).ToLowerInvariant();
    }
}

public sealed class LibraryException(string message) : Exception(message)
{
    public static LibraryException EmptyName() => new(Loc.S("名称不能为空"));
    public static LibraryException DuplicateGroupName(string name) => new(Loc.S("已存在名为「%@」的分组", name));
    public static LibraryException DuplicateTagName(string name) => new(Loc.S("已存在名为「%@」的标签", name));
    public static LibraryException GroupDepthExceeded() => new(Loc.S("分组最多支持两级"));
    public static LibraryException NotFound() => new(Loc.S("找不到该项目"));
}
