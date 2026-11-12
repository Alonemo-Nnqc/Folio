using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Folio.Core;

/// <summary>A journal's ranks from easyScholar (META-30): the dataset abbreviations of its open API (sciUp, sci, sciif…)
/// mapped to their texts ("医学1区", "Q1", "12.3"), cached per journal for 30 days. Empty Ranks means easyScholar does not
/// list the journal. The macOS app stores the same table (journalMetrics) and parses it by the same rules
/// (FolioCore JournalMetrics.swift).</summary>
public sealed record JournalMetrics(IReadOnlyDictionary<string, string> Ranks, DateTime FetchedAt)
{
    public static readonly TimeSpan MaximumAge = TimeSpan.FromDays(30);

    public bool IsIndexed => Ranks.Count > 0;

    public bool IsFresh(DateTime? now = null)
    {
        var n = now ?? DateTime.UtcNow;
        return n - FetchedAt < MaximumAge && FetchedAt <= n.AddDays(1);
    }

    string? Value(string key) => Ranks.TryGetValue(key, out var v) && v.Trim().Length > 0 ? v.Trim() : null;

    // Parsed fields

    /// <summary>中科院分区升级版 (sciUp): zone 1…4.</summary>
    public int? CasZone => Value("sciUp") is { } v ? Zone(v) : null;
    public string? CasCategory => Value("sciUp") is { } v ? Category(v) : null;
    public bool CasTop => Value("sciUpTop") != null || (Value("sciUp")?.Contains("top", StringComparison.OrdinalIgnoreCase) ?? false);
    public int? CasBaseZone => Value("sciBase") is { } v ? Zone(v) : null;
    public string? CasBaseCategory => Value("sciBase") is { } v ? Category(v) : null;
    public string? CasSmall => Value("sciUpSmall");
    public int? JcrQuartile => Value("sci") is { } v ? Quartile(v) : null;
    public int? SsciQuartile => Value("ssci") is { } v ? Quartile(v) : null;
    public double? ImpactFactor => Value("sciif") is { } v ? Number(v) : null;
    public double? ImpactFactor5Year => Value("sciif5") is { } v ? Number(v) : null;
    public string? Ccf => Value("ccf") is { } v ? CcfClass(v) : null;
    public bool IsEI => Value("eii") != null;
    public string? Warning => Value("sciwarn");
    public bool Pku => Value("pku") != null;
    public bool Cssci => Value("cssci") != null;
    public bool Cscd => Value("cscd") != null;

    // Lenient parsing (values are free text: "医学1区", "Q1", "12.3", "CCF-A")

    public static int? Zone(string text)
    {
        var m = Regex.Match(text, @"([1-4])\s*区");
        if (m.Success) return int.Parse(m.Groups[1].Value);
        var digits = new string(text.Where(char.IsDigit).ToArray());
        return digits.Length == 1 && digits[0] is >= '1' and <= '4' ? digits[0] - '0' : null;
    }

    public static string? Category(string text)
    {
        var m = Regex.Match(text, @"^(.*?)\s*[1-4]\s*区");
        if (!m.Success) return null;
        var name = m.Groups[1].Value.Trim();
        return name.Length == 0 ? null : name;
    }

    public static int? Quartile(string text)
    {
        var m = Regex.Match(text, @"[Qq]\s*([1-4])");
        if (m.Success) return int.Parse(m.Groups[1].Value);
        var digits = new string(text.Where(char.IsDigit).ToArray());
        return digits.Length == 1 && digits[0] is >= '1' and <= '4' ? digits[0] - '0' : null;
    }

    public static double? Number(string text)
    {
        var m = Regex.Match(text, @"\d+(?:\.\d+)?");
        return m.Success ? double.Parse(m.Value, CultureInfo.InvariantCulture) : null;
    }

    public static string? CcfClass(string text)
    {
        var rest = text.ToUpperInvariant().Replace("CCF", "");
        var c = rest.FirstOrDefault(ch => "ABC".Contains(ch));
        return c == default ? null : c.ToString();
    }

    /// <summary>"分区" column order: 中科院 zone (Top first within a zone), then JCR quartile for journals without one.</summary>
    public double? RankSortKey => CasZone is { } zone ? zone * 10 + (CasTop ? 0 : 5) : JcrQuartile is { } q ? 100 + q * 10 : null;

    /// <summary>Kinds of capsule, for their colours: cas1…cas4, q1…q4, if, if5, ccf, index, warning.</summary>
    public sealed record Badge(string Kind, string Text, string Detail, bool Emphasized = false);

    /// <summary>The capsules under the journal name, most telling first.</summary>
    public List<Badge> Badges
    {
        get
        {
            var list = new List<Badge>();
            if (CasZone is { } zone)
            {
                var text = Loc.S("中科院 %lld 区", zone) + (CasTop ? " Top" : "");
                var lines = new List<string> { Loc.S("中科院分区（升级版）：%@", ZoneText(CasCategory, zone)) + (CasTop ? Loc.S("，Top 期刊") : "") };
                if (CasBaseZone is { } b) lines.Add(Loc.S("中科院分区（基础版）：%@", ZoneText(CasBaseCategory, b)));
                if (CasSmall is { } small) lines.Add(Loc.S("小类：%@", small));
                list.Add(new Badge($"cas{zone}", text, string.Join("\n", lines), CasTop));
            }
            else if (CasBaseZone is { } b)
                list.Add(new Badge($"cas{b}", Loc.S("中科院 %lld 区", b), Loc.S("中科院分区（基础版）：%@", ZoneText(CasBaseCategory, b))));
            if (JcrQuartile is { } q) list.Add(new Badge($"q{q}", $"JCR Q{q}", Loc.S("JCR 分区（Clarivate）：%@", $"Q{q}")));
            if (ImpactFactor is { } f) list.Add(new Badge("if", $"IF {Format(f)}", Loc.S("影响因子（JCR）：%@", Format(f))));
            if (ImpactFactor5Year is { } f5) list.Add(new Badge("if5", Loc.S("5 年 IF %@", Format(f5)), Loc.S("5 年影响因子（JCR）：%@", Format(f5))));
            if (SsciQuartile is { } sq) list.Add(new Badge($"q{sq}", $"SSCI Q{sq}", Loc.S("SSCI 分区（Clarivate）：%@", $"Q{sq}")));
            if (Ccf is { } ccf) list.Add(new Badge("ccf", $"CCF {ccf}", Loc.S("中国计算机学会推荐：%@ 类", ccf)));
            if (IsEI) list.Add(new Badge("index", "EI", Loc.S("EI 检索")));
            if (Cssci) list.Add(new Badge("index", "CSSCI", Loc.S("南大核心（CSSCI）")));
            if (Pku) list.Add(new Badge("index", Loc.S("北大核心"), Loc.S("北大中文核心期刊")));
            if (Cscd) list.Add(new Badge("index", "CSCD", Loc.S("中国科学引文数据库")));
            if (Warning is { } w) list.Add(new Badge("warning", Loc.S("预警"), Loc.S("中科院国际期刊预警名单：%@", w)));
            return list;
        }
    }

    /// <summary>One line for tooltips and AI tools: "中科院 1 区 Top · JCR Q1 · IF 12.3".</summary>
    public string Summary => string.Join(" · ", Badges.Select(b => b.Text));

    /// <summary>The "分区" column: the 中科院 zone, else the JCR quartile.</summary>
    public string? RankText => CasZone is { } zone ? Loc.S("%lld 区", zone) + (CasTop ? " Top" : "")
        : CasBaseZone is { } b ? Loc.S("%lld 区", b)
        : JcrQuartile is { } q ? $"Q{q}" : null;

    static string ZoneText(string? category, int zone) => category is { } c ? $"{c} {Loc.S("%lld 区", zone)}" : Loc.S("%lld 区", zone);

    /// <summary>"12.3", "0.85", "105": at most three decimals, no trailing zeros.</summary>
    public static string Format(double value)
    {
        var text = value.ToString("0.000", CultureInfo.InvariantCulture).TrimEnd('0');
        return text.EndsWith('.') ? text[..^1] : text;
    }

    // Journal names

    /// <summary>The cache key of a journal name: case, spacing, "&amp;amp;" and trailing dots do not matter.</summary>
    public static string Key(string name)
    {
        var text = Regex.Replace(name, "&amp;", "&", RegexOptions.IgnoreCase);
        text = string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        text = text.TrimEnd('.', ',', ';');
        return text.Trim().ToLowerInvariant();
    }

    /// <summary>The name sent to easyScholar: "&amp;amp;" decoded, spaces collapsed.</summary>
    public static string QueryName(string name) =>
        string.Join(' ', Regex.Replace(name, "&amp;", "&", RegexOptions.IgnoreCase).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    static readonly HashSet<string> UnrankedVenues = ["arxiv", "biorxiv", "medrxiv", "chemrxiv", "ssrn", "research square",
                                                      "preprints", "techrxiv", "openreview", "psyarxiv", "osf preprints"];

    /// <summary>The journal name an item's metrics are looked up by, or null when it has none worth asking about.</summary>
    public static string? JournalName(Item item)
    {
        if (item.Kind != ItemKind.Regular || item.Type is not (ItemType.JournalArticle or ItemType.ConferencePaper)) return null;
        var source = item.Source?.Trim();
        if (source == null || source.Length < 2) return null;
        var key = Key(source);
        if (key.Length == 0 || UnrankedVenues.Contains(key) || key.StartsWith("arxiv")) return null;
        return source;
    }

    // Storage (the journalMetrics table: name, json, fetchedAt)

    public string Json => JsonSerializer.Serialize(new SortedDictionary<string, string>(Ranks.ToDictionary(kv => kv.Key, kv => kv.Value), StringComparer.Ordinal),
        new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });

    public static JournalMetrics FromJson(string json, DateTime fetchedAt)
    {
        Dictionary<string, string>? ranks = null;
        try { ranks = JsonSerializer.Deserialize<Dictionary<string, string>>(json); } catch (JsonException) { }
        return new JournalMetrics(ranks ?? [], fetchedAt);
    }
}
