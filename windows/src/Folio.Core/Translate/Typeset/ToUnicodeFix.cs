using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Folio.Core.Translate.Typeset;

/// <summary>Skia writes a font's ToUnicode map by asking the font which character each glyph stands for, and Chinese
/// fonts draw a Kangxi radical (⼀ U+2F00) and its ideograph (一 U+4E00) with one glyph: copied or searched text then
/// comes out as radicals. Their compatibility mappings (NFKC) lead back to the ideographs.</summary>
public static partial class ToUnicodeFix
{
    static bool NeedsFix(int cp) => cp is >= 0x2E80 and <= 0x2FDF or >= 0xF900 and <= 0xFAFF or >= 0x2F800 and <= 0x2FA1F;

    static string Decode(string hex)
    {
        var bytes = Convert.FromHexString(hex);
        return Encoding.BigEndianUnicode.GetString(bytes);
    }

    static string Encode(string text) => Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(text));

    static string Fixed(string text)
    {
        if (!text.EnumerateRunes().Any(r => NeedsFix(r.Value))) return text;
        var sb = new StringBuilder();
        foreach (var rune in text.EnumerateRunes())
            sb.Append(NeedsFix(rune.Value) ? rune.ToString().Normalize(NormalizationForm.FormKC) : rune.ToString());
        return sb.ToString();
    }

    [GeneratedRegex(@"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>")]
    private static partial Regex Range();

    [GeneratedRegex(@"(\d+)\s+beginbfrange(.*?)endbfrange", RegexOptions.Singleline)]
    private static partial Regex RangeBlock();

    [GeneratedRegex(@"(\d+)\s+beginbfchar(.*?)endbfchar", RegexOptions.Singleline)]
    private static partial Regex CharBlock();

    [GeneratedRegex(@"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>")]
    private static partial Regex Pair();

    /// <summary>The CMap with radicals and compatibility ideographs mapped to unified ideographs; null when nothing changes.</summary>
    public static byte[]? Apply(byte[] data)
    {
        var text = Encoding.Latin1.GetString(data);
        if (!text.Contains("begincmap") || !text.Contains("beginbf")) return null;
        bool changed = false;
        var extra = new List<(string Code, string Target)>();
        text = CharBlock().Replace(text, block => block.Groups[1].Value + " beginbfchar" + Pair().Replace(block.Groups[2].Value, m =>
        {
            var target = Decode(m.Groups[2].Value);
            var fixedTarget = Fixed(target);
            if (fixedTarget == target) return m.Value;
            changed = true;
            return $"<{m.Groups[1].Value}> <{Encode(fixedTarget)}>";
        }) + "endbfchar");
        // A range whose characters change is written out one by one.
        text = RangeBlock().Replace(text, block =>
        {
            var kept = new List<string>();
            foreach (Match m in Range().Matches(block.Groups[2].Value))
            {
                int lo = int.Parse(m.Groups[1].Value, NumberStyles.HexNumber), hi = int.Parse(m.Groups[2].Value, NumberStyles.HexNumber);
                var first = Decode(m.Groups[3].Value);
                int digits = m.Groups[1].Value.Length;
                bool any = false;
                var singles = new List<(string, string)>();
                for (int code = lo; code <= hi && code - lo < 256; code++)
                {
                    var target = first.Length == 0 ? first : first[..^1] + (char)(first[^1] + (code - lo));
                    var fixedTarget = Fixed(target);
                    any |= fixedTarget != target;
                    singles.Add((code.ToString("X" + digits), fixedTarget));
                }
                if (any) { extra.AddRange(singles); changed = true; }
                else kept.Add(m.Value);
            }
            return kept.Count == 0 ? "" : $"{kept.Count} beginbfrange\n{string.Join("\n", kept)}\nendbfrange";
        });
        if (!changed) return null;
        if (extra.Count > 0)
        {
            var sb = new StringBuilder();
            foreach (var chunk in extra.Chunk(100))
            {
                sb.Append(chunk.Length).Append(" beginbfchar\n");
                foreach (var (code, target) in chunk) sb.Append('<').Append(code).Append("> <").Append(Encode(target)).Append(">\n");
                sb.Append("endbfchar\n");
            }
            int at = text.IndexOf("endcmap", StringComparison.Ordinal);
            text = at >= 0 ? text.Insert(at, sb.ToString()) : text + sb;
        }
        return Encoding.Latin1.GetBytes(text);
    }
}
