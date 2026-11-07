using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Folio.Core;

/// <summary>
/// Interface strings. The keys are the Simplified Chinese source strings of the macOS app and the English
/// translations come from its String Catalogs (embedded as they are), so both apps say exactly the same things.
/// Strings only Windows needs live in Resources/Windows.xcstrings, in the same format.
/// </summary>
public static partial class Loc
{
    static readonly Lazy<Dictionary<string, string>> English = new(LoadEnglish);
    static bool? _english;

    /// <summary>"zh-Hans", "en" or null (follow the system). Set at startup from the settings.</summary>
    public static string? Override { get; set; }

    public static bool IsEnglish
    {
        get
        {
            if (Override == "en") return true;
            if (Override == "zh-Hans") return false;
            return _english ??= !CultureInfo.CurrentUICulture.Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>The string for the interface language. Format placeholders follow the catalogs: %@, %lld, %1$@ …</summary>
    public static string S(string key, params object?[] args)
    {
        var format = IsEnglish && English.Value.TryGetValue(key, out var en) ? en : key;
        return args.Length == 0 ? Unescape(format) : Format(format, args);
    }

    /// <summary>Applies printf-style placeholders as the catalogs write them.</summary>
    public static string Format(string format, params object?[] args)
    {
        int next = 0;
        var result = Placeholder().Replace(format, m =>
        {
            if (m.Value == "%%") return "%";
            int index = m.Groups[1].Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) - 1 : next++;
            if (index < 0 || index >= args.Length) return m.Value;
            var arg = args[index];
            var spec = m.Groups[2].Value;
            if (spec.EndsWith('f') && arg is IConvertible c)
            {
                var precision = Regex.Match(spec, @"\.(\d+)").Groups[1].Value;
                return c.ToDouble(CultureInfo.InvariantCulture).ToString("F" + (precision == "" ? "6" : precision), CultureInfo.InvariantCulture);
            }
            return Convert.ToString(arg, CultureInfo.InvariantCulture) ?? "";
        });
        return result;
    }

    static string Unescape(string s) => s.Contains("%%") ? s.Replace("%%", "%") : s;

    [GeneratedRegex(@"%(?:(\d+)\$)?((?:\.\d+)?(?:lld|ld|d|@|f|u|lu|llu))|%%")]
    private static partial Regex Placeholder();

    static Dictionary<string, string> LoadEnglish()
    {
        var map = new Dictionary<string, string>();
        var assembly = Assembly.GetExecutingAssembly();
        foreach (var name in assembly.GetManifestResourceNames().Where(n => n.StartsWith("strings.", StringComparison.Ordinal)).Order())
        {
            using var stream = assembly.GetManifestResourceStream(name)!;
            using var doc = JsonDocument.Parse(stream);
            if (!doc.RootElement.TryGetProperty("strings", out var strings)) continue;
            foreach (var entry in strings.EnumerateObject())
            {
                if (!entry.Value.TryGetProperty("localizations", out var locs) || !locs.TryGetProperty("en", out var en)) continue;
                if (StringUnit(en) is { } value) map[entry.Name] = value;
            }
        }
        return map;
    }

    /// <summary>The English value: a plain string unit, or the "other" plural form.</summary>
    static string? StringUnit(JsonElement en)
    {
        if (en.TryGetProperty("stringUnit", out var unit) && unit.TryGetProperty("value", out var value)) return value.GetString();
        if (en.TryGetProperty("variations", out var variations))
        {
            foreach (var kind in variations.EnumerateObject())
                foreach (var form in kind.Value.EnumerateObject())
                    if (form.Name == "other" && form.Value.TryGetProperty("stringUnit", out var u) && u.TryGetProperty("value", out var v))
                        return v.GetString();
        }
        return null;
    }

    /// <summary>All English strings (for checks in tests).</summary>
    public static IReadOnlyDictionary<string, string> EnglishTable => English.Value;

    public static string JoinList(IEnumerable<string> parts)
    {
        var list = parts.ToList();
        if (list.Count <= 1) return string.Concat(list);
        if (!IsEnglish) return string.Join("、", list);
        var sb = new StringBuilder();
        for (int i = 0; i < list.Count; i++)
        {
            if (i > 0) sb.Append(i == list.Count - 1 ? (list.Count > 2 ? ", and " : " and ") : ", ");
            sb.Append(list[i]);
        }
        return sb.ToString();
    }
}
