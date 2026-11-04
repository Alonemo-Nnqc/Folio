using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Jint;
using Jint.Native;

namespace Folio.Core.Citation;

public enum CitationStyle { Bibtex, Gbt7714, Apa, Ieee, Mla, Chicago, Harvard, Vancouver, Nature }

public static class CitationStyles
{
    public static readonly CitationStyle[] All = Enum.GetValues<CitationStyle>();

    public static string Raw(this CitationStyle s) => s.ToString().ToLowerInvariant();

    public static string DisplayName(this CitationStyle s) => s switch
    {
        CitationStyle.Bibtex => "BibTeX",
        CitationStyle.Gbt7714 => "GB/T 7714-2015",
        CitationStyle.Apa => Loc.S("APA 第 7 版"),
        CitationStyle.Ieee => "IEEE",
        CitationStyle.Mla => Loc.S("MLA 第 9 版"),
        CitationStyle.Chicago => Loc.S("Chicago 第 18 版（作者-日期）"),
        CitationStyle.Harvard => "Harvard",
        CitationStyle.Vancouver => "Vancouver",
        _ => "Nature",
    };

    internal static string? CslResource(this CitationStyle s) => s switch
    {
        CitationStyle.Bibtex => null,
        CitationStyle.Gbt7714 => "china-national-standard-gb-t-7714-2015-numeric",
        CitationStyle.Apa => "apa",
        CitationStyle.Ieee => "ieee",
        CitationStyle.Mla => "modern-language-association",
        CitationStyle.Chicago => "chicago-author-date",
        CitationStyle.Harvard => "harvard-cite-them-right",
        CitationStyle.Vancouver => "nlm-citation-sequence",
        _ => "nature",
    };

    public static CitationStyle? Named(string raw)
    {
        var key = new string(raw.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());
        foreach (var s in All) if (s.Raw() == key) return s;
        return key switch
        {
            "gbt" or "gb" or "gbt77142015" or "gb7714" or "国标" => CitationStyle.Gbt7714,
            "apa7" or "apa7th" => CitationStyle.Apa,
            "mla9" or "mla9th" or "modernlanguageassociation" => CitationStyle.Mla,
            "chicagoauthordate" or "chicago18" or "chicago17" => CitationStyle.Chicago,
            "citethemright" or "harvardcitethemright" => CitationStyle.Harvard,
            "nlm" or "icmje" or "citingmedicine" => CitationStyle.Vancouver,
            "bib" or "latex" => CitationStyle.Bibtex,
            _ => null,
        };
    }
}

public sealed record CitationEntry(string Id, string CitationKey, Metadata Metadata);

public sealed record CitationOutput(string PlainText, string? Html = null);

/// <summary>
/// Formats bibliographies with citeproc-js and the CSL styles bundled with the macOS app, run in Jint (the macOS
/// app runs the same script in JavaScriptCore). Not thread-safe; use one instance per thread or lock around it.
/// </summary>
public sealed class CslRenderer
{
    readonly Engine _js;
    readonly JsValue _engineCtor;
    readonly JsValue _sys;
    readonly Dictionary<CitationStyle, JsValue> _engines = [];
    Dictionary<string, JsonObject> _items = [];

    public CslRenderer()
    {
        _js = new Engine(o => o.LimitRecursion(4096).Strict(false));
        _js.Execute("var module = { exports: {} }; var exports = module.exports;");
        _js.Execute(Resource("citeproc_commonjs.js"));
        _engineCtor = _js.Evaluate("module.exports.Engine");
        if (_engineCtor.IsUndefined()) throw new InvalidOperationException(Loc.S("citeproc-js 未导出 CSL.Engine"));
        _js.SetValue("CSL", _js.Evaluate("module.exports"));
        var locales = new Dictionary<string, string>
        {
            ["en-US"] = Resource("locales-en-US.xml"),
            ["zh-CN"] = Resource("locales-zh-CN.xml"),
        };
        _js.SetValue("__retrieveItemJson", new Func<string, string>(id => _items.TryGetValue(id, out var item) ? item.ToJsonString() : "{}"));
        _js.SetValue("__retrieveLocale", new Func<string, string>(lang => locales.GetValueOrDefault(lang) ?? locales["en-US"]));
        _sys = _js.Evaluate("({ retrieveItem: function (id) { return JSON.parse(__retrieveItemJson(String(id))); }, retrieveLocale: function (lang) { return __retrieveLocale(String(lang)); } })");
    }

    static string Resource(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("csl." + name)
            ?? throw new FileNotFoundException(Loc.S("缺少引用导出所需的资源文件：%@", name));
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    JsValue EngineFor(CitationStyle style)
    {
        if (_engines.TryGetValue(style, out var cached)) return cached;
        var xml = Resource(style.CslResource()! + ".csl");
        // English locale terms regardless of the style's default-locale, as on macOS.
        var engine = _js.Construct(_engineCtor, _sys, xml, "en-US", true);
        _engines[style] = engine;
        return engine;
    }

    public CitationOutput Render(IReadOnlyList<CitationEntry> entries, CitationStyle style)
    {
        if (entries.Count == 0) return new CitationOutput("");
        if (style == CitationStyle.Bibtex) return new CitationOutput(BibTeXWriter.Document(entries));
        var engine = EngineFor(style);
        _items = entries.ToDictionary(e => e.Id, e => CslJsonMapper.CslJson(e.Id, e.Metadata));
        var ids = JsValue.FromObject(_js, entries.Select(e => e.Id).ToArray());
        Invoke(engine, "setOutputFormat", "text");
        Invoke(engine, "updateItems", ids);
        var lines = BibliographyEntries(engine).Select(CleanTextEntry).ToList();
        if (style == CitationStyle.Gbt7714) lines = lines.Select(StrippingNumericLabel).ToList();
        string? html = null;
        if (style != CitationStyle.Gbt7714)
        {
            Invoke(engine, "setOutputFormat", "html");
            var result = Invoke(engine, "makeBibliography");
            var meta = result.Get("0");
            html = meta.Get("bibstart").ToString() + string.Concat(StringsOf(result.Get("1"))) + meta.Get("bibend").ToString();
        }
        return new CitationOutput(string.Join('\n', lines), html);
    }

    public (List<string> Each, string Combined) InTextCitations(IReadOnlyList<CitationEntry> entries, CitationStyle style)
    {
        if (entries.Count == 0) return ([], "");
        if (style == CitationStyle.Bibtex)
        {
            var keys = entries.Select(e => e.CitationKey).ToList();
            return (keys.Select(k => $"\\cite{{{k}}}").ToList(), $"\\cite{{{string.Join(',', keys)}}}");
        }
        var engine = EngineFor(style);
        _items = entries.ToDictionary(e => e.Id, e => CslJsonMapper.CslJson(e.Id, e.Metadata));
        Invoke(engine, "setOutputFormat", "text");
        Invoke(engine, "updateItems", JsValue.FromObject(_js, entries.Select(e => e.Id).ToArray()));
        string Cluster(IEnumerable<string> ids) =>
            Invoke(engine, "makeCitationCluster", _js.Evaluate("(" + JsonSerializer.Serialize(ids.Select(id => new { id })) + ")")).ToString();
        return (entries.Select(e => Cluster([e.Id])).ToList(), Cluster(entries.Select(e => e.Id)));
    }

    JsValue Invoke(JsValue target, string method, params JsValue[] args)
    {
        try { return _js.Invoke(target.Get(method), target, args); }
        catch (Exception e) { throw new InvalidOperationException(Loc.S("citeproc-js 出错：%@", e.Message), e); }
    }

    IEnumerable<string> BibliographyEntries(JsValue engine) => StringsOf(Invoke(engine, "makeBibliography").Get("1"));

    static IEnumerable<string> StringsOf(JsValue array)
    {
        if (!array.IsArray()) yield break;
        var arr = array.AsArray();
        for (uint i = 0; i < arr.Length; i++) yield return arr[i].ToString();
    }

    static string CleanTextEntry(string entry)
    {
        var line = entry.Trim().Replace("\t", " ").Replace("\n", " ");
        var m = Regex.Match(line, @"^(\[\d+\]|\d+\.)(?=\S)");
        if (m.Success) line = line.Insert(m.Length, " ");
        return line;
    }

    static string StrippingNumericLabel(string line)
    {
        if (!line.StartsWith('[')) return line;
        int closing = line.IndexOf(']');
        if (closing < 0) return line;
        var label = line[1..closing];
        if (label.Length == 0 || !label.All(char.IsDigit)) return line;
        return line[(closing + 1)..].TrimStart(' ');
    }
}

static class CslJsonMapper
{
    public static JsonObject CslJson(string id, Metadata m)
    {
        var item = new JsonObject
        {
            ["id"] = id,
            ["type"] = CslType(m.Type),
            ["title"] = m.Title,
            ["language"] = ContainsCjk(m.Title) ? "zh" : "en",
        };
        if (m.Authors.Count > 0)
            item["author"] = new JsonArray(m.Authors.Select(a => (JsonNode)(a.Given.Trim().Length == 0
                ? new JsonObject { ["literal"] = a.Family }
                : new JsonObject { ["family"] = a.Family, ["given"] = a.Given.Trim() })).ToArray());
        var parts = m.Date?.Split('-').Select(p => int.TryParse(p, out var n) ? (int?)n : null).Where(n => n != null).Select(n => n!.Value).ToList();
        if (parts is { Count: > 0 }) item["issued"] = new JsonObject { ["date-parts"] = new JsonArray(new JsonArray(parts.Select(p => (JsonNode)p).ToArray())) };
        else if (m.Year is { } y) item["issued"] = new JsonObject { ["date-parts"] = new JsonArray(new JsonArray(y)) };
        bool repositoryPreprint = m.Type == ItemType.Preprint && m.ArxivId != null;
        if (!string.IsNullOrEmpty(m.Source) && !(repositoryPreprint && m.Source.Equals("arxiv", StringComparison.OrdinalIgnoreCase))) item["container-title"] = m.Source;
        if (repositoryPreprint)
        {
            item["publisher"] = "arXiv";
            item["number"] = $"arXiv:{m.ArxivId}";
            if (string.IsNullOrEmpty(m.Doi)) item["DOI"] = $"10.48550/arXiv.{m.ArxivId}";
            if (string.IsNullOrEmpty(m.Url)) item["URL"] = $"https://arxiv.org/abs/{m.ArxivId}";
        }
        if (!string.IsNullOrEmpty(m.Volume)) item["volume"] = m.Volume;
        if (!string.IsNullOrEmpty(m.Issue)) item["issue"] = m.Issue;
        if (!string.IsNullOrEmpty(m.Pages)) item["page"] = m.Pages;
        if (!string.IsNullOrEmpty(m.Publisher) && !repositoryPreprint) item["publisher"] = m.Publisher;
        if (!string.IsNullOrEmpty(m.Doi)) item["DOI"] = m.Doi;
        if (!string.IsNullOrEmpty(m.Url)) item["URL"] = m.Url;
        if (!string.IsNullOrEmpty(m.Abstract)) item["abstract"] = m.Abstract;
        return item;
    }

    public static string CslType(ItemType t) => t switch
    {
        ItemType.JournalArticle => "article-journal",
        ItemType.ConferencePaper => "paper-conference",
        ItemType.Preprint => "article",
        ItemType.Book => "book",
        ItemType.BookChapter => "chapter",
        ItemType.Thesis => "thesis",
        ItemType.Report => "report",
        ItemType.Webpage => "webpage",
        ItemType.Dataset => "dataset",
        _ => "document",
    };

    static bool ContainsCjk(string text) => text.Any(c => c is >= '一' and <= '鿿' or >= '㐀' and <= '䶿' or >= '぀' and <= 'ヿ');
}

public static class BibTeXWriter
{
    public static string Entry(CitationEntry entry)
    {
        var m = entry.Metadata;
        var fields = new List<(string, string)> { ("author", string.Join(" and ", m.Authors.Select(a => Escape(AuthorFormatter.Full(a))))), ("title", ProtectAcronyms(Escape(m.Title))) };
        fields.AddRange(ExtraFields(m));
        return $"@{Kind(m.Type)}{{{entry.CitationKey},\n{string.Join(",\n", fields.Select(f => $"  {f.Item1} = {{{f.Item2}}}"))}\n}}";
    }

    public static string Document(IEnumerable<CitationEntry> entries) => string.Join("\n\n", entries.Select(Entry)) + "\n";

    static string Kind(ItemType t) => t switch
    {
        ItemType.JournalArticle => "article",
        ItemType.ConferencePaper => "inproceedings",
        ItemType.Book => "book",
        ItemType.BookChapter => "incollection",
        ItemType.Thesis => "phdthesis",
        ItemType.Report => "techreport",
        _ => "misc",
    };

    static List<(string, string)> ExtraFields(Metadata m)
    {
        var fields = new List<(string, string)>();
        void Add(string name, string? value) { if (!string.IsNullOrEmpty(value)) fields.Add((name, Escape(value))); }
        var year = m.Year?.ToString(CultureInfo.InvariantCulture) ?? (m.Date is { Length: >= 4 } d ? d[..4] : null);
        var pages = string.IsNullOrEmpty(m.Pages) ? null : m.Pages.Contains("--") ? m.Pages : m.Pages.Replace("-", "--");
        switch (m.Type)
        {
            case ItemType.JournalArticle:
                Add("journal", m.Source); Add("year", year); Add("volume", m.Volume); Add("number", m.Issue); Add("pages", pages); Add("doi", m.Doi); break;
            case ItemType.ConferencePaper:
                Add("booktitle", m.Source); Add("year", year); Add("volume", m.Volume); Add("pages", pages); Add("doi", m.Doi); break;
            case ItemType.Preprint:
                Add("year", year);
                if (!string.IsNullOrEmpty(m.ArxivId)) { fields.Add(("eprint", Escape(m.ArxivId))); fields.Add(("archivePrefix", "arXiv")); }
                Add("doi", m.Doi); Add("url", m.Url); break;
            case ItemType.Book:
                Add("publisher", m.Publisher); Add("year", year); Add("isbn", m.Isbn); Add("doi", m.Doi); Add("url", m.Url); break;
            case ItemType.BookChapter:
                Add("booktitle", m.Source); Add("publisher", m.Publisher); Add("year", year); Add("pages", pages); Add("doi", m.Doi); break;
            case ItemType.Thesis:
                Add("school", m.Source); Add("year", year); Add("doi", m.Doi); Add("url", m.Url); break;
            case ItemType.Report:
                Add("institution", m.Source); Add("year", year); Add("doi", m.Doi); Add("url", m.Url); break;
            default:
                Add("year", year); Add("note", m.Source); Add("url", m.Url); Add("doi", m.Doi); break;
        }
        return fields;
    }

    static string ProtectAcronyms(string text) => Regex.Replace(text, @"\S*[A-Z]{2,}\S*", m => "{" + m.Value + "}");

    public static string Escape(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var ch in text)
        {
            sb.Append(ch switch
            {
                '\\' => "\\textbackslash{}",
                '&' => "\\&",
                '%' => "\\%",
                '$' => "\\$",
                '#' => "\\#",
                '_' => "\\_",
                '{' => "\\{",
                '}' => "\\}",
                '~' => "\\textasciitilde{}",
                '^' => "\\textasciicircum{}",
                _ => ch.ToString(),
            });
        }
        return sb.ToString();
    }
}

public enum ReferenceFormat { Bibtex, Ris, Csljson }

public sealed record ReferenceRecord(Metadata Metadata, string? CitationKey, List<string> Keywords);

public static class ReferenceFormats
{
    public static string DisplayName(this ReferenceFormat f) => f switch { ReferenceFormat.Bibtex => "BibTeX", ReferenceFormat.Ris => "RIS", _ => "CSL JSON" };
    public static string FileExtension(this ReferenceFormat f) => f switch { ReferenceFormat.Bibtex => "bib", ReferenceFormat.Ris => "ris", _ => "json" };

    public static ReferenceFormat? Detect(string text)
    {
        var t = text.Trim();
        if (t.StartsWith("TY  - ") || t.Contains("\nTY  - ")) return ReferenceFormat.Ris;
        if (Regex.IsMatch(t, @"@[A-Za-z]+\s*[\{\(]")) return ReferenceFormat.Bibtex;
        if (t.StartsWith('[') || t.StartsWith('{')) return ReferenceFormat.Csljson;
        return null;
    }

    public static string Render(this ReferenceFormat f, IReadOnlyList<CitationEntry> entries) => f switch
    {
        ReferenceFormat.Bibtex => BibTeXWriter.Document(entries),
        ReferenceFormat.Ris => RisWriter.Document(entries),
        _ => CslJsonWriter.Document(entries),
    };

    public static List<ReferenceRecord> Parse(string text) => Detect(text) switch
    {
        ReferenceFormat.Bibtex => BibTeXReader.Parse(text),
        ReferenceFormat.Ris => RisReader.Parse(text),
        ReferenceFormat.Csljson => CslJsonReader.Parse(text),
        _ => [],
    };
}

static class BibTeXReader
{
    public static List<ReferenceRecord> Parse(string text)
    {
        var records = new List<ReferenceRecord>();
        int i = 0;
        while (i < text.Length)
        {
            if (text[i] != '@') { i++; continue; }
            int j = i + 1;
            while (j < text.Length && char.IsLetter(text[j])) j++;
            var kind = text[(i + 1)..j].ToLowerInvariant();
            while (j < text.Length && char.IsWhiteSpace(text[j])) j++;
            if (j >= text.Length || (text[j] != '{' && text[j] != '(')) { i = j; continue; }
            char open = text[j], close = open == '{' ? '}' : ')';
            int depth = 0, braces = 0, k = j;
            do
            {
                char c = text[k];
                if (open == '{') { if (c == '{') depth++; else if (c == '}') depth--; }
                else
                {
                    if (c == '{') braces++; else if (c == '}') braces--;
                    else if (braces == 0 && c == '(') depth++; else if (braces == 0 && c == close) depth--;
                }
                k++;
            } while (k < text.Length && depth > 0);
            var body = text[(j + 1)..Math.Max(j + 1, k - 1)];
            i = k;
            if (kind is "comment" or "string" or "preamble") continue;
            if (Entry(kind, body) is { } record) records.Add(record);
        }
        return records;
    }

    static ReferenceRecord? Entry(string kind, string body)
    {
        int comma = body.IndexOf(',');
        if (comma < 0) return null;
        var key = body[..comma].Trim();
        var fields = ParseFields(body[(comma + 1)..]);
        if (fields.GetValueOrDefault("title") is not { } rawTitle || Clean(rawTitle) is not { Length: > 0 } title) return null;
        var m = new Metadata(title) { Type = TypeFor(kind, fields) };
        m.Authors = (fields.GetValueOrDefault("author") ?? fields.GetValueOrDefault("editor")) is { } a ? Authors(a) : [];
        if (fields.GetValueOrDefault("year") is { } y && int.TryParse(new string(Clean(y).Take(4).ToArray()), out var year)) m.Year = year;
        if (fields.GetValueOrDefault("date") is { } dt && Clean(dt) is { Length: > 0 } date)
        {
            m.Date = date;
            if (m.Year == null && int.TryParse(new string(date.Take(4).ToArray()), out var yy)) m.Year = yy;
        }
        m.Source = new[] { "journal", "journaltitle", "booktitle", "school", "institution", "howpublished" }.Select(fields.GetValueOrDefault).FirstOrDefault(v => v != null) is { } src ? Clean(src) : null;
        m.Volume = fields.GetValueOrDefault("volume") is { } v ? Clean(v) : null;
        m.Issue = (fields.GetValueOrDefault("number") ?? fields.GetValueOrDefault("issue")) is { } n ? Clean(n) : null;
        m.Pages = fields.GetValueOrDefault("pages") is { } p ? Clean(p.Replace("--", "-")) : null;
        m.Publisher = (fields.GetValueOrDefault("publisher") ?? fields.GetValueOrDefault("organization")) is { } pub ? Clean(pub) : null;
        m.Doi = fields.GetValueOrDefault("doi") is { } doi ? Clean(doi).ToLowerInvariant().Replace("https://doi.org/", "") : null;
        m.Url = fields.GetValueOrDefault("url") is { } url ? Clean(url) : null;
        m.Isbn = fields.GetValueOrDefault("isbn") is { } isbn ? Clean(isbn) : null;
        m.Abstract = fields.GetValueOrDefault("abstract") is { } abs ? Clean(abs) : null;
        if (fields.GetValueOrDefault("eprint") is { } eprint
            && (fields.GetValueOrDefault("archiveprefix") ?? fields.GetValueOrDefault("eprinttype")) is { } prefix && Clean(prefix).Equals("arxiv", StringComparison.OrdinalIgnoreCase))
        {
            m.ArxivId = Clean(eprint);
            if (m.Type == ItemType.JournalArticle && m.Source == null) { m.Type = ItemType.Preprint; m.Source = "arXiv"; }
        }
        var keywords = fields.GetValueOrDefault("keywords") is { } kw
            ? Clean(kw).Split([',', ';']).Select(s => s.Trim()).Where(s => s.Length > 0).ToList() : [];
        return new ReferenceRecord(m, key.Length == 0 ? null : key, keywords);
    }

    static ItemType TypeFor(string kind, Dictionary<string, string> fields) => kind switch
    {
        "article" => ItemType.JournalArticle,
        "inproceedings" or "conference" or "proceedings" => ItemType.ConferencePaper,
        "book" => ItemType.Book,
        "incollection" or "inbook" => ItemType.BookChapter,
        "phdthesis" or "mastersthesis" or "thesis" => ItemType.Thesis,
        "techreport" or "report" => ItemType.Report,
        "online" or "electronic" => ItemType.Webpage,
        "dataset" => ItemType.Dataset,
        "unpublished" or "misc" => fields.GetValueOrDefault("archiveprefix")?.ToLowerInvariant().Contains("arxiv") == true ? ItemType.Preprint : ItemType.Other,
        _ => ItemType.Other,
    };

    public static Dictionary<string, string> ParseFields(string text)
    {
        var fields = new Dictionary<string, string>();
        int i = 0;
        while (i < text.Length)
        {
            while (i < text.Length && (char.IsWhiteSpace(text[i]) || text[i] == ',')) i++;
            int j = i;
            while (j < text.Length && text[j] != '=') j++;
            if (j >= text.Length) break;
            var name = text[i..j].Trim().ToLowerInvariant();
            j++;
            var value = new StringBuilder();
            while (j < text.Length)
            {
                while (j < text.Length && char.IsWhiteSpace(text[j])) j++;
                if (j >= text.Length) break;
                if (text[j] == '{')
                {
                    int depth = 0, k = j;
                    do
                    {
                        if (text[k] == '{') depth++; else if (text[k] == '}') depth--;
                        k++;
                    } while (k < text.Length && depth > 0);
                    value.Append(text[(j + 1)..(k - 1)]);
                    j = k;
                }
                else if (text[j] == '"')
                {
                    int k = j + 1, depth = 0;
                    while (k < text.Length && !(text[k] == '"' && depth == 0))
                    {
                        if (text[k] == '{') depth++; else if (text[k] == '}') depth--;
                        k++;
                    }
                    value.Append(text[(j + 1)..Math.Min(k, text.Length)]);
                    j = k + 1;
                }
                else
                {
                    int k = j;
                    while (k < text.Length && text[k] != ',' && text[k] != '#' && text[k] != '\n') k++;
                    value.Append(text[j..k].Trim());
                    j = k;
                }
                while (j < text.Length && char.IsWhiteSpace(text[j])) j++;
                if (j < text.Length && text[j] == '#') { j++; continue; }
                break;
            }
            if (name.Length > 0) fields[name] = value.ToString();
            i = j;
        }
        return fields;
    }

    public static List<Author> Authors(string field) => Clean(field).Split(" and ").Select(raw =>
    {
        var name = raw.Trim();
        if (name.Length == 0 || name.Equals("others", StringComparison.OrdinalIgnoreCase)) return null;
        int comma = name.IndexOf(',');
        if (comma >= 0) return new Author(name[..comma].Trim(), name[(comma + 1)..].Trim());
        var parts = name.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 1 ? new Author(parts[^1], string.Join(' ', parts[..^1])) : new Author(name);
    }).OfType<Author>().ToList();

    static readonly (string, string)[] Accents =
    [
        ("\\\"a", "ä"), ("\\\"o", "ö"), ("\\\"u", "ü"), ("\\\"A", "Ä"), ("\\\"O", "Ö"), ("\\\"U", "Ü"),
        ("\\'e", "é"), ("\\'a", "á"), ("\\'i", "í"), ("\\'o", "ó"), ("\\'u", "ú"), ("\\'E", "É"), ("\\'c", "ć"),
        ("\\`e", "è"), ("\\`a", "à"), ("\\^e", "ê"), ("\\^o", "ô"), ("\\~n", "ñ"), ("\\c c", "ç"), ("\\c{c}", "ç"),
        ("\\ss", "ß"), ("\\o", "ø"), ("\\aa", "å"), ("\\&", "&"), ("\\%", "%"), ("\\_", "_"), ("\\$", "$"),
        ("\\textendash", "–"), ("\\textemdash", "—"), ("--", "–"), ("~", " "),
    ];

    public static string Clean(string value)
    {
        var text = value;
        foreach (var (from, to) in Accents)
        {
            text = text.Replace(from, to);
            if (from.Length == 3)
            {
                var command = from[..2];
                var letter = from[^1];
                text = text.Replace($"{{{command}{letter}}}", to).Replace($"{command}{{{letter}}}", to);
            }
        }
        return Text.CollapseWhitespace(text.Replace("{", "").Replace("}", ""));
    }
}

static class RisReader
{
    public static List<ReferenceRecord> Parse(string text)
    {
        var records = new List<ReferenceRecord>();
        var tags = new List<(string, string)>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length < 5 || !line[2..].StartsWith("  -")) continue;
            var tag = line[..2];
            var value = line.Length > 6 ? line[6..].Trim() : "";
            if (tag == "ER")
            {
                if (Record(tags) is { } r) records.Add(r);
                tags = [];
            }
            else tags.Add((tag, value));
        }
        if (tags.Count > 0 && Record(tags) is { } last) records.Add(last);
        return records;
    }

    static ReferenceRecord? Record(List<(string Tag, string Value)> tags)
    {
        string? First(params string[] names) => names.Select(n => tags.FirstOrDefault(t => t.Tag == n && t.Value.Length > 0).Value).FirstOrDefault(v => v != null);
        if (First("TI", "T1", "CT", "BT") is not { } title) return null;
        var m = new Metadata(title)
        {
            Type = First("TY") switch
            {
                "JOUR" or "JFULL" or "MGZN" => ItemType.JournalArticle,
                "CONF" or "CPAPER" => ItemType.ConferencePaper,
                "BOOK" or "EBOOK" => ItemType.Book,
                "CHAP" or "ECHAP" => ItemType.BookChapter,
                "THES" => ItemType.Thesis,
                "RPRT" => ItemType.Report,
                "ELEC" or "WEB" => ItemType.Webpage,
                "DATA" => ItemType.Dataset,
                "UNPB" or "PREPRINT" => ItemType.Preprint,
                _ => ItemType.Other,
            },
        };
        m.Authors = tags.Where(t => t.Tag is "AU" or "A1" or "A2").Take(200).SelectMany(t => BibTeXReader.Authors(t.Value)).ToList();
        if (First("PY", "Y1", "DA") is { } date && int.TryParse(new string(date.Take(4).ToArray()), out var y)) m.Year = y;
        m.Source = First("T2", "JO", "JF", "JA", "T3");
        m.Volume = First("VL");
        m.Issue = First("IS");
        if (First("SP") is { } start) m.Pages = First("EP") is { } end ? $"{start}-{end}" : start;
        m.Publisher = First("PB");
        m.Doi = First("DO")?.ToLowerInvariant().Replace("https://doi.org/", "");
        m.Url = First("UR");
        m.Isbn = First("SN");
        m.Abstract = First("AB", "N2");
        return new ReferenceRecord(m, First("ID"), tags.Where(t => t.Tag == "KW").Select(t => t.Value).ToList());
    }
}

static class RisWriter
{
    public static string Document(IReadOnlyList<CitationEntry> entries) => string.Join("\n", entries.Select(Entry)) + (entries.Count == 0 ? "" : "\n");

    static string Entry(CitationEntry e)
    {
        var m = e.Metadata;
        var lines = new List<string>();
        void Add(string tag, string? value) { if (!string.IsNullOrEmpty(value)) lines.Add($"{tag}  - {value.Replace("\n", " ")}"); }
        Add("TY", m.Type switch
        {
            ItemType.JournalArticle => "JOUR",
            ItemType.ConferencePaper => "CPAPER",
            ItemType.Preprint => "UNPB",
            ItemType.Book => "BOOK",
            ItemType.BookChapter => "CHAP",
            ItemType.Thesis => "THES",
            ItemType.Report => "RPRT",
            ItemType.Webpage => "ELEC",
            ItemType.Dataset => "DATA",
            _ => "GEN",
        });
        Add("ID", e.CitationKey);
        Add("TI", m.Title);
        foreach (var a in m.Authors) Add("AU", a.Given.Length == 0 ? a.Family : $"{a.Family}, {a.Given}");
        Add("PY", m.Year?.ToString(CultureInfo.InvariantCulture));
        Add("DA", m.Date);
        Add("T2", m.Source);
        Add("VL", m.Volume);
        Add("IS", m.Issue);
        if (m.Pages != null)
        {
            var parts = m.Pages.Split('-', 2);
            Add("SP", parts[0]);
            if (parts.Length > 1) Add("EP", parts[1]);
        }
        Add("PB", m.Publisher);
        Add("DO", m.Doi);
        Add("UR", m.Url);
        Add("SN", m.Isbn);
        Add("AB", m.Abstract);
        lines.Add("ER  - ");
        return string.Join('\n', lines);
    }
}

static class CslJsonWriter
{
    public static string Document(IReadOnlyList<CitationEntry> entries)
    {
        var items = new JsonArray(entries.Select(e => (JsonNode)Sorted(CslJsonMapper.CslJson(e.CitationKey, e.Metadata))).ToArray());
        return items.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) + "\n";
    }

    static JsonObject Sorted(JsonObject o) => new(o.OrderBy(kv => kv.Key, StringComparer.Ordinal).Select(kv => new KeyValuePair<string, JsonNode?>(kv.Key, kv.Value?.DeepClone())));
}

static class CslJsonReader
{
    public static List<ReferenceRecord> Parse(string text)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(text); } catch (JsonException) { return []; }
        var items = root is JsonArray a ? a.OfType<JsonObject>().ToList() : root is JsonObject o ? [o] : [];
        var result = new List<ReferenceRecord>();
        foreach (var item in items)
        {
            if (item["title"]?.GetValue<string>() is not { Length: > 0 } title) continue;
            var m = new Metadata(title)
            {
                Type = (item["type"]?.ToString()) switch
                {
                    "article-journal" => ItemType.JournalArticle,
                    "paper-conference" => ItemType.ConferencePaper,
                    "article" => ItemType.Preprint,
                    "book" => ItemType.Book,
                    "chapter" => ItemType.BookChapter,
                    "thesis" => ItemType.Thesis,
                    "report" => ItemType.Report,
                    "webpage" => ItemType.Webpage,
                    "dataset" => ItemType.Dataset,
                    _ => ItemType.Other,
                },
                Authors = (item["author"] as JsonArray ?? []).OfType<JsonObject>().Select(n =>
                    n["literal"] is { } lit ? new Author(lit.ToString()) : n["family"] is { } fam ? new Author(fam.ToString(), n["given"]?.ToString() ?? "") : null)
                    .OfType<Author>().ToList(),
                Source = item["container-title"]?.ToString(),
                Volume = item["volume"]?.ToString(),
                Issue = item["issue"]?.ToString(),
                Pages = item["page"]?.ToString(),
                Publisher = item["publisher"]?.ToString(),
                Doi = item["DOI"]?.ToString().ToLowerInvariant(),
                Url = item["URL"]?.ToString(),
                Abstract = item["abstract"]?.ToString(),
            };
            if (item["issued"]?["date-parts"] is JsonArray { Count: > 0 } dp && dp[0] is JsonArray first)
            {
                var numbers = first.Select(x => int.TryParse(x?.ToString(), out var n) ? (int?)n : null).Where(n => n != null).Select(n => n!.Value).ToList();
                m.Year = numbers.Count > 0 ? numbers[0] : null;
                if (numbers.Count > 1) m.Date = string.Join('-', numbers.Select(n => n.ToString("00", CultureInfo.InvariantCulture)));
            }
            result.Add(new ReferenceRecord(m, item["id"]?.ToString(), []));
        }
        return result;
    }
}
