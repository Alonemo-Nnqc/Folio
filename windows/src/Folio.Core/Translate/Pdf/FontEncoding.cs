using System.Text;
using System.Text.RegularExpressions;

namespace Folio.Core.Translate.Pdf;

// Port of macos/.../FolioTranslate/PDF/FontEncoding.swift.

/// <summary>
/// How a font's strings split into character codes, which CID each code selects (composite fonts), and the Unicode
/// text of each code: from the ToUnicode CMap, else the encoding (base encoding, Differences, the embedded Type 1
/// program's own encoding), glyph names read through the Adobe Glyph List and TeX's names. Text the font states is
/// reliable; text inferred from a default encoding is not.
/// </summary>
public sealed partial class FontEncoding
{
    readonly Dictionary<int, string> _known = [];
    readonly Dictionary<int, string> _guessed = [];
    /// <summary>Glyph names of a simple font's codes (Differences, the Type 1 program's encoding).</summary>
    public Dictionary<int, string> Names { get; private set; } = [];
    readonly List<(int Length, byte[] Low, byte[] High)> _codespace = [];
    readonly Dictionary<int, int> _cids = [];
    readonly List<(int Low, int High, int First)> _cidRanges = [];
    bool _identity = true;
    bool _codeIsUnicode;
    public bool IsComposite { get; }

    public FontEncoding(PDict font)
    {
        IsComposite = font.Name("Subtype") == "Type0";
        if (IsComposite) ReadCMap(font);
        else
        {
            var (known, guessed, names) = SimpleEncoding(font);
            _known = known; _guessed = guessed; Names = names;
        }
        if (font.Stream("ToUnicode") is { } stream)
            foreach (var (code, text) in ParseToUnicode(stream.Data))
                if (Usable(text)) _known[code] = text;
    }

    // MARK: Codes

    public List<(int Code, int Length)> Codes(byte[] data)
    {
        if (!IsComposite) return data.Select(b => ((int)b, 1)).ToList();
        var result = new List<(int, int)>(data.Length / 2);
        for (int i = 0; i < data.Length;)
        {
            int length = CodeLength(data, i);
            int code = 0;
            for (int k = 0; k < length; k++) code = code << 8 | (i + k < data.Length ? data[i + k] : 0);
            result.Add((code, length));
            i += length;
        }
        return result;
    }

    int CodeLength(byte[] bytes, int i)
    {
        if (_codespace.Count == 0) return 2;
        for (int length = 1; length <= 4; length++)
        {
            if (i + length > bytes.Length) break;
            foreach (var range in _codespace)
            {
                if (range.Length != length) continue;
                bool inside = true;
                for (int k = 0; k < length; k++)
                    if (bytes[i + k] < range.Low[k] || bytes[i + k] > range.High[k]) { inside = false; break; }
                if (inside) return length;
            }
        }
        return Math.Max(1, Math.Min(_codespace.Min(r => r.Length), bytes.Length - i));
    }

    /// <summary>The CID a code selects (composite fonts); the code itself for simple fonts.</summary>
    public int Cid(int code)
    {
        if (!IsComposite || _identity) return code;
        if (_cids.TryGetValue(code, out var cid)) return cid;
        foreach (var r in _cidRanges) if (code >= r.Low && code <= r.High) return r.First + code - r.Low;
        return 0;
    }

    // MARK: Text

    public (string Text, bool Reliable)? Text(int code)
    {
        if (_known.TryGetValue(code, out var known)) return (known, true);
        if (_codeIsUnicode && code is >= 0 and <= 0x10FFFF and not (>= 0xD800 and <= 0xDFFF))
        {
            var s = char.ConvertFromUtf32(code);
            if (Usable(s)) return (s, true);
        }
        if (_guessed.TryGetValue(code, out var guessed)) return (guessed, false);
        return null;
    }

    /// <summary>Text worth using: not empty, not control characters, not the private use area.</summary>
    public static bool Usable(string text) =>
        text.Length > 0 && !text.EnumerateRunes().Any(r => r.Value < 0x20 || r.Value is >= 0xE000 and <= 0xF8FF || r.Value == 0xFFFD);

    // MARK: CMaps

    void ReadCMap(PDict dict)
    {
        if (dict.Name("Encoding") is { } name)
        {
            if (name is "Identity-H" or "Identity-V") return;
            _identity = false;
            if (name.Contains("UCS2") || name.Contains("UTF16")) _codeIsUnicode = true;
            else if (name.Contains("RKSJ"))
                _codespace.AddRange([(1, [0x00], [0x80]), (1, [0xA0], [0xDF]), (2, [0x81, 0x40], [0x9F, 0xFC]), (2, [0xE0, 0x40], [0xFC, 0xFC])]);
            else _codespace.AddRange([(1, [0x00], [0x80]), (2, [0x81, 0x40], [0xFE, 0xFE])]);
        }
        else if (dict.Stream("Encoding") is { } stream)
        {
            _identity = false;
            foreach (var op in ContentLexer.Parse(stream.Data))
            {
                var o = op.Operands;
                switch (op.Name)
                {
                    case "endcodespacerange":
                        for (int k = 0; k + 1 < o.Count; k += 2)
                            if (o[k] is ContentOperand.Str lo && o[k + 1] is ContentOperand.Str hi && lo.Value.Length == hi.Value.Length && lo.Value.Length is >= 1 and <= 4)
                                _codespace.Add((lo.Value.Length, lo.Value, hi.Value));
                        break;
                    case "endcidrange":
                        for (int k = 0; k + 2 < o.Count; k += 3)
                            if (CodeOf(o[k]) is { } lo && CodeOf(o[k + 1]) is { } hi && o[k + 2].AsNumber is { } first && hi >= lo)
                                _cidRanges.Add((lo, hi, (int)first));
                        break;
                    case "endcidchar":
                        for (int k = 0; k + 1 < o.Count; k += 2)
                            if (CodeOf(o[k]) is { } c && o[k + 1].AsNumber is { } cid) _cids[c] = (int)cid;
                        break;
                }
            }
            if (_cids.Count == 0 && _cidRanges.Count == 1 && _cidRanges[0].Low == 0 && _cidRanges[0].First == 0) _identity = true;
        }
    }

    static int? CodeOf(ContentOperand operand)
    {
        if (operand is not ContentOperand.Str s || s.Value.Length is 0 or > 4) return null;
        return s.Value.Aggregate(0, (acc, b) => acc << 8 | b);
    }

    /// <summary>bfchar and bfrange entries of a ToUnicode CMap.</summary>
    public static Dictionary<int, string> ParseToUnicode(byte[] data)
    {
        var result = new Dictionary<int, string>();
        static string? Unicode(ContentOperand operand)
        {
            if (operand is not ContentOperand.Str s || s.Value.Length == 0) return null;
            var bytes = s.Value;
            var units = new List<char>();
            for (int i = 0; i + 1 < bytes.Length; i += 2) units.Add((char)(bytes[i] << 8 | bytes[i + 1]));
            if (bytes.Length % 2 == 1) units.Add((char)bytes[^1]);
            return new string(units.ToArray());
        }
        foreach (var op in ContentLexer.Parse(data))
        {
            var o = op.Operands;
            if (op.Name == "endbfchar")
            {
                for (int k = 0; k + 1 < o.Count; k += 2)
                {
                    if (CodeOf(o[k]) is not { } c) continue;
                    if (Unicode(o[k + 1]) is { } u) result[c] = u;
                    else if (o[k + 1].AsName is { } name && GlyphNames.Unicode(name) is { } g) result[c] = g;
                }
            }
            else if (op.Name == "endbfrange")
            {
                for (int k = 0; k + 2 < o.Count; k += 3)
                {
                    if (CodeOf(o[k]) is not { } lo || CodeOf(o[k + 1]) is not { } hi || hi < lo || hi - lo >= 65536) continue;
                    switch (o[k + 2])
                    {
                        case ContentOperand.Array items:
                            for (int offset = 0; offset < items.Items.Count && lo + offset <= hi; offset++)
                                if (Unicode(items.Items[offset]) is { } u) result[lo + offset] = u;
                            break;
                        case ContentOperand.Str s:
                            if (Unicode(s) is not { Length: > 0 } start) continue;
                            var units = start.ToCharArray();
                            for (int c = lo; c <= hi; c++)
                            {
                                result[c] = new string(units);
                                units[^1] = (char)(units[^1] + 1);
                            }
                            break;
                    }
                }
            }
        }
        return result;
    }

    // MARK: Simple fonts

    static (Dictionary<int, string> Known, Dictionary<int, string> Guessed, Dictionary<int, string> Names) SimpleEncoding(PDict dict)
    {
        var known = new Dictionary<int, string>();
        var guessed = new Dictionary<int, string>();
        var names = new Dictionary<int, string>();
        string? @base = dict.Name("Encoding");
        PArray? differences = null;
        if (dict.Dict("Encoding") is { } encoding)
        {
            @base = encoding.Name("BaseEncoding");
            differences = encoding.Array("Differences");
        }
        var descriptor = dict.Dict("FontDescriptor");
        int flags = (int)(descriptor?.Number("Flags") ?? 0);
        bool symbolic = (flags & 4) != 0 && (flags & 32) == 0;
        var subtype = dict.Name("Subtype");
        var baseFont = dict.Name("BaseFont") ?? "";
        if (@base != null)
        {
            bool stated = !(symbolic && subtype == "TrueType");
            for (int code = 0; code <= 255; code++)
                if (BaseText(code, @base) is { } text) { if (stated) known[code] = text; else guessed[code] = text; }
        }
        else if ((subtype is "Type1" or "MMType1") && descriptor?.Stream("FontFile") is { } program && Type1Encoding(program.Data) is { } builtIn)
        {
            names = builtIn;
            foreach (var (code, name) in builtIn) if (GlyphNames.Unicode(name) is { } u) known[code] = u;
        }
        else if (baseFont.EndsWith("Symbol", StringComparison.Ordinal))
        {
            foreach (var (code, text) in SymbolEncoding) known[code] = text;
        }
        else if (!symbolic)
        {
            for (int code = 0; code <= 255; code++) if (BaseText(code, "StandardEncoding") is { } text) guessed[code] = text;
        }
        if (differences != null)
        {
            int code = 0;
            for (int i = 0; i < differences.Count; i++)
            {
                if (differences.Number(i) is { } number) code = (int)number;
                else if (differences.Name(i) is { } name)
                {
                    guessed.Remove(code);
                    names[code] = name;
                    if (GlyphNames.Unicode(name) is { } u) known[code] = u; else known.Remove(code);
                    code++;
                }
            }
        }
        return (known, guessed, names);
    }

    static readonly Encoding Cp1252 = CodePagesEncodingProvider.Instance.GetEncoding(1252)!;
    static readonly Encoding MacRoman = CodePagesEncodingProvider.Instance.GetEncoding(10000)!;

    public static string? BaseText(int code, string encoding)
    {
        if (code is < 32 or >= 256) return null;
        var bytes = new[] { (byte)code };
        switch (encoding)
        {
            case "MacRomanEncoding":
                return code == 127 ? null : MacRoman.GetString(bytes);
            case "StandardEncoding":
                if (StandardOverrides.TryGetValue(code, out var o)) return o;
                return code < 127 ? ((char)code).ToString() : null;
            default:
                if (code == 0xAD) return "-";
                if (code is 127 or 129 or 141 or 143 or 144 or 157) return null;
                return Cp1252.GetString(bytes);
        }
    }

    [GeneratedRegex(@"dup\s+(\d+)\s*/([^\s/\[\]{}()<>]+)\s+put")]
    private static partial Regex DupPut();

    /// <summary>The encoding vector (code → glyph name) in the clear-text part of a Type 1 font program.</summary>
    public static Dictionary<int, string>? Type1Encoding(byte[] program)
    {
        var text = Encoding.Latin1.GetString(program, 0, Math.Min(program.Length, 65536));
        int start = text.IndexOf("/Encoding", StringComparison.Ordinal);
        if (start < 0) return null;
        var rest = text[(start + 9)..];
        if (rest[..Math.Min(40, rest.Length)].Contains("StandardEncoding")) return StandardNames;
        int end = rest.IndexOf("readonly def", StringComparison.Ordinal);
        if (end < 0) end = rest.IndexOf("eexec", StringComparison.Ordinal);
        if (end < 0) end = rest.Length;
        var map = new Dictionary<int, string>();
        foreach (Match m in DupPut().Matches(rest[..end]))
            if (int.TryParse(m.Groups[1].Value, out var code) && code < 256) map[code] = m.Groups[2].Value;
        return map.Count == 0 ? null : map;
    }

    static readonly Lazy<Dictionary<int, string>> StandardNamesLazy = new(() =>
    {
        var reverse = new Dictionary<string, string>();
        foreach (var (name, text) in GlyphNames.Table)
            if (!reverse.TryGetValue(text, out var existing) || name.Length < existing.Length) reverse[text] = name;
        var map = new Dictionary<int, string>();
        for (int code = 32; code <= 255; code++)
        {
            if (BaseText(code, "StandardEncoding") is not { } t) continue;
            if (reverse.TryGetValue(t, out var n)) map[code] = n;
            else if (t.Length == 1 && char.IsLetter(t[0])) map[code] = t;
        }
        return map;
    });
    static Dictionary<int, string> StandardNames => StandardNamesLazy.Value;

    static readonly Dictionary<int, string> StandardOverrides = new()
    {
        [39] = "’", [96] = "‘", [161] = "¡", [162] = "¢", [163] = "£", [164] = "⁄", [165] = "¥", [166] = "ƒ", [167] = "§", [168] = "¤", [169] = "'", [170] = "“",
        [171] = "«", [172] = "‹", [173] = "›", [174] = "fi", [175] = "fl", [177] = "–", [178] = "†", [179] = "‡", [180] = "·", [182] = "¶", [183] = "•",
        [184] = "‚", [185] = "„", [186] = "”", [187] = "»", [188] = "…", [189] = "‰", [191] = "¿", [193] = "`", [194] = "´", [195] = "ˆ", [196] = "˜",
        [197] = "¯", [198] = "˘", [199] = "˙", [200] = "¨", [202] = "˚", [203] = "¸", [205] = "˝", [206] = "˛", [207] = "ˇ", [208] = "—", [225] = "Æ",
        [227] = "ª", [232] = "Ł", [233] = "Ø", [234] = "Œ", [235] = "º", [241] = "æ", [245] = "ı", [248] = "ł", [249] = "ø", [250] = "œ", [251] = "ß",
    };

    static readonly Lazy<Dictionary<int, string>> SymbolLazy = new(() =>
    {
        var map = new Dictionary<int, string>();
        const string ascii = " !∀#∃%&∋()∗+,−./0123456789:;<=>?≅ΑΒΧΔΕΦΓΗΙϑΚΛΜΝΟΠΘΡΣΤΥςΩΞΨΖ[∴]⊥_‾αβχδεφγηιϕκλμνοπθρστυϖωξψζ{|}∼";
        int offset = 0;
        foreach (var rune in ascii.EnumerateRunes()) map[32 + offset++] = rune.ToString();
        (int, string)[] high =
        [
            (0xA1, "ϒ"), (0xA2, "′"), (0xA3, "≤"), (0xA4, "⁄"), (0xA5, "∞"), (0xA6, "ƒ"), (0xA7, "♣"), (0xA8, "♦"), (0xA9, "♥"), (0xAA, "♠"),
            (0xAB, "↔"), (0xAC, "←"), (0xAD, "↑"), (0xAE, "→"), (0xAF, "↓"), (0xB0, "°"), (0xB1, "±"), (0xB2, "″"), (0xB3, "≥"), (0xB4, "×"),
            (0xB5, "∝"), (0xB6, "∂"), (0xB7, "•"), (0xB8, "÷"), (0xB9, "≠"), (0xBA, "≡"), (0xBB, "≈"), (0xBC, "…"), (0xC0, "ℵ"), (0xC1, "ℑ"),
            (0xC2, "ℜ"), (0xC3, "℘"), (0xC4, "⊗"), (0xC5, "⊕"), (0xC6, "∅"), (0xC7, "∩"), (0xC8, "∪"), (0xC9, "⊃"), (0xCA, "⊇"), (0xCB, "⊄"),
            (0xCC, "⊂"), (0xCD, "⊆"), (0xCE, "∈"), (0xCF, "∉"), (0xD0, "∠"), (0xD1, "∇"), (0xD5, "∏"), (0xD6, "√"), (0xD7, "⋅"), (0xD8, "¬"),
            (0xD9, "∧"), (0xDA, "∨"), (0xDB, "⇔"), (0xDC, "⇐"), (0xDD, "⇑"), (0xDE, "⇒"), (0xDF, "⇓"), (0xE0, "◊"), (0xE1, "〈"), (0xE5, "∑"),
            (0xF1, "〉"), (0xF2, "∫"),
        ];
        foreach (var (code, text) in high) map[code] = text;
        return map;
    });
    static Dictionary<int, string> SymbolEncoding => SymbolLazy.Value;
}

/// <summary>Glyph names to Unicode: the common part of the Adobe Glyph List, TeX's names, and uniXXXX / uXXXX.</summary>
public static class GlyphNames
{
    public static string? Unicode(string raw)
    {
        var name = raw;
        int dot = name.IndexOf('.');
        if (dot > 0) name = name[..dot];
        if (name.Contains('_') && !name.StartsWith('_'))
        {
            var parts = name.Split('_', StringSplitOptions.RemoveEmptyEntries).Select(Unicode).ToList();
            if (parts.Count > 0 && parts.All(p => p != null)) return string.Concat(parts);
        }
        if (Table.TryGetValue(name, out var text)) return text;
        if (name.Length == 1 && char.IsLetterOrDigit(name[0])) return name;
        if (name.StartsWith("uni") && name.Length >= 7 && uint.TryParse(name.AsSpan(3, 4), System.Globalization.NumberStyles.HexNumber, null, out var v) && Valid(v))
            return char.ConvertFromUtf32((int)v);
        if (name.StartsWith('u') && name.Length is >= 5 and <= 7 && uint.TryParse(name.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out var u) && Valid(u))
            return char.ConvertFromUtf32((int)u);
        foreach (var suffix in new[] { "display", "text", "Bigg", "bigg", "Big", "big", "BIG", "1", "2" })
            if (name.EndsWith(suffix, StringComparison.Ordinal) && name.Length > suffix.Length && Table.TryGetValue(name[..^suffix.Length], out var t)) return t;
        return null;
    }

    static bool Valid(uint v) => v <= 0x10FFFF && v is not (>= 0xD800 and <= 0xDFFF);

    public static readonly Dictionary<string, string> Table = Build();

    static Dictionary<string, string> Build()
    {
        var t = new Dictionary<string, string>
        {
            ["space"] = " ", ["exclam"] = "!", ["quotedbl"] = "\"", ["numbersign"] = "#", ["dollar"] = "$", ["percent"] = "%", ["ampersand"] = "&",
            ["quoteright"] = "’", ["quotesingle"] = "'", ["parenleft"] = "(", ["parenright"] = ")", ["asterisk"] = "*", ["plus"] = "+", ["comma"] = ",",
            ["hyphen"] = "-", ["period"] = ".", ["slash"] = "/", ["colon"] = ":", ["semicolon"] = ";", ["less"] = "<", ["equal"] = "=", ["greater"] = ">",
            ["question"] = "?", ["at"] = "@", ["bracketleft"] = "[", ["backslash"] = "\\", ["bracketright"] = "]", ["asciicircum"] = "^",
            ["underscore"] = "_", ["quoteleft"] = "‘", ["grave"] = "`", ["braceleft"] = "{", ["bar"] = "|", ["braceright"] = "}", ["asciitilde"] = "~",
            ["zero"] = "0", ["one"] = "1", ["two"] = "2", ["three"] = "3", ["four"] = "4", ["five"] = "5", ["six"] = "6", ["seven"] = "7", ["eight"] = "8", ["nine"] = "9",
            ["fi"] = "fi", ["fl"] = "fl", ["ff"] = "ff", ["ffi"] = "ffi", ["ffl"] = "ffl", ["dotlessi"] = "ı", ["dotlessj"] = "ȷ", ["exclamdown"] = "¡",
            ["questiondown"] = "¿", ["quotedblleft"] = "“", ["quotedblright"] = "”", ["quotesinglbase"] = "‚", ["quotedblbase"] = "„",
            ["endash"] = "–", ["emdash"] = "—", ["bullet"] = "•", ["dagger"] = "†", ["daggerdbl"] = "‡", ["section"] = "§", ["paragraph"] = "¶",
            ["periodcentered"] = "·", ["ellipsis"] = "…", ["copyright"] = "©", ["registered"] = "®", ["trademark"] = "™", ["degree"] = "°",
            ["guillemotleft"] = "«", ["guillemotright"] = "»", ["guilsinglleft"] = "‹", ["guilsinglright"] = "›", ["perthousand"] = "‰",
            ["sterling"] = "£", ["yen"] = "¥", ["cent"] = "¢", ["currency"] = "¤", ["florin"] = "ƒ", ["fraction"] = "⁄", ["ordfeminine"] = "ª",
            ["ordmasculine"] = "º", ["brokenbar"] = "¦", ["onehalf"] = "½", ["onequarter"] = "¼", ["threequarters"] = "¾",
            ["onesuperior"] = "¹", ["twosuperior"] = "²", ["threesuperior"] = "³", ["mu1"] = "µ", ["logicalnot"] = "¬",
            ["germandbls"] = "ß", ["ae"] = "æ", ["AE"] = "Æ", ["oe"] = "œ", ["OE"] = "Œ", ["oslash"] = "ø", ["Oslash"] = "Ø", ["lslash"] = "ł", ["Lslash"] = "Ł",
            ["eth"] = "ð", ["Eth"] = "Ð", ["thorn"] = "þ", ["Thorn"] = "Þ",
            ["acute"] = "´", ["circumflex"] = "ˆ", ["tilde"] = "˜", ["macron"] = "¯", ["breve"] = "˘", ["dotaccent"] = "˙", ["dieresis"] = "¨",
            ["ring"] = "˚", ["cedilla"] = "¸", ["hungarumlaut"] = "˝", ["ogonek"] = "˛", ["caron"] = "ˇ", ["hacek"] = "ˇ", ["tie"] = "⁀",
            ["minus"] = "−", ["multiply"] = "×", ["divide"] = "÷", ["plusminus"] = "±", ["minusplus"] = "∓", ["infinity"] = "∞", ["partialdiff"] = "∂",
            ["nabla"] = "∇", ["gradient"] = "∇", ["summation"] = "∑", ["product"] = "∏", ["coproduct"] = "∐", ["integral"] = "∫", ["contintegral"] = "∮",
            ["contourintegral"] = "∮", ["radical"] = "√", ["element"] = "∈", ["notelement"] = "∉", ["owner"] = "∋", ["subset"] = "⊂", ["superset"] = "⊃",
            ["reflexsubset"] = "⊆", ["reflexsuperset"] = "⊇", ["propersubset"] = "⊂", ["propersuperset"] = "⊃", ["subsetequal"] = "⊆",
            ["supersetequal"] = "⊇", ["intersection"] = "∩", ["union"] = "∪", ["unionmulti"] = "⊎", ["unionsq"] = "⊔", ["intersectionsq"] = "⊓",
            ["logicaland"] = "∧", ["logicalor"] = "∨", ["similar"] = "∼", ["similarequal"] = "≃", ["approxequal"] = "≈", ["congruent"] = "≅",
            ["notequal"] = "≠", ["lessequal"] = "≤", ["greaterequal"] = "≥", ["equivalence"] = "≡", ["proportional"] = "∝",
            ["arrowright"] = "→", ["arrowleft"] = "←", ["arrowup"] = "↑", ["arrowdown"] = "↓", ["arrowboth"] = "↔", ["arrowupdown"] = "↕",
            ["arrowdblright"] = "⇒", ["arrowdblleft"] = "⇐", ["arrowdblboth"] = "⇔", ["arrowdblup"] = "⇑", ["arrowdbldown"] = "⇓",
            ["arrownortheast"] = "↗", ["arrowsoutheast"] = "↘", ["arrownorthwest"] = "↖", ["arrowsouthwest"] = "↙",
            ["universal"] = "∀", ["existential"] = "∃", ["emptyset"] = "∅", ["angbracketleft"] = "⟨", ["angbracketright"] = "⟩", ["prime"] = "′",
            ["dotmath"] = "⋅", ["asteriskmath"] = "∗", ["openbullet"] = "◦", ["circlemultiply"] = "⊗", ["circleplus"] = "⊕", ["circledot"] = "⊙",
            ["circleminus"] = "⊖", ["circledivide"] = "⊘", ["circlecopyrt"] = "◯", ["perpendicular"] = "⊥", ["angle"] = "∠", ["therefore"] = "∴",
            ["aleph"] = "ℵ", ["weierstrass"] = "℘", ["Ifraktur"] = "ℑ", ["Rfraktur"] = "ℜ", ["floorleft"] = "⌊", ["floorright"] = "⌋",
            ["ceilingleft"] = "⌈", ["ceilingright"] = "⌉", ["bardbl"] = "‖", ["mapsto"] = "↦", ["lessmuch"] = "≪", ["greatermuch"] = "≫",
            ["precedes"] = "≺", ["follows"] = "≻", ["precedesequal"] = "⪯", ["followsequal"] = "⪰", ["turnstileleft"] = "⊢", ["turnstileright"] = "⊣",
            ["latticetop"] = "⊤", ["triangle"] = "△", ["triangleinv"] = "▽", ["triangleleft"] = "◁", ["triangleright"] = "▷", ["star"] = "⋆",
            ["diamond"] = "⋄", ["diamondmath"] = "⋄", ["heart"] = "♡", ["club"] = "♣", ["spade"] = "♠", ["checkmark"] = "✓", ["xmark"] = "✗",
            ["backslashmath"] = "∖", ["setminus"] = "∖", ["wreathproduct"] = "≀", ["negationslash"] = "̸", ["square"] = "□", ["lozenge"] = "◊",
            ["colonequal"] = "≔", ["defines"] = "≜", ["hbar"] = "ℏ", ["planckover2pi"] = "ℏ", ["planckover2pi1"] = "ℏ",
            ["ell"] = "ℓ", ["lscript"] = "ℓ", ["wp"] = "℘", ["dotlessi1"] = "ı", ["tie1"] = "⁀", ["flat1"] = "♭", ["Re"] = "ℜ", ["Im"] = "ℑ", ["vector"] = "⃗", ["harpoonleftright"] = "⇌",
            ["arrowhookleft"] = "↩", ["arrowhookright"] = "↪", ["notsubset"] = "⊄", ["notsuperset"] = "⊅",
            ["sharp"] = "♯", ["flat"] = "♭", ["natural"] = "♮", ["bottom"] = "⊥", ["top"] = "⊤", ["parallel"] = "∥", ["divides"] = "∣",
            ["visiblespace"] = "␣", ["slurabove"] = "⌢", ["slurbelow"] = "⌣", ["followsorequal"] = "⪰", ["precedesorequal"] = "⪯",
            ["bracketleftbt"] = "⎣", ["bracketrightbt"] = "⎦", ["bracketlefttp"] = "⎡", ["bracketrighttp"] = "⎤",
            ["bracketleftex"] = "⎢", ["bracketrightex"] = "⎥", ["parenlefttp"] = "⎛", ["parenleftbt"] = "⎝", ["parenleftex"] = "⎜",
            ["parenrighttp"] = "⎞", ["parenrightbt"] = "⎠", ["parenrightex"] = "⎟", ["bracelefttp"] = "⎧", ["braceleftmid"] = "⎨",
            ["braceleftbt"] = "⎩", ["bracerighttp"] = "⎫", ["bracerightmid"] = "⎬", ["bracerightbt"] = "⎭", ["braceex"] = "⎪",
            ["integraltp"] = "⌠", ["integralbt"] = "⌡", ["radicalex"] = "⎷", ["arrowvertex"] = "⏐", ["arrowdblvertex"] = "‖",
            ["hatwide"] = "ˆ", ["tildewide"] = "˜", ["hatwider"] = "ˆ", ["tildewider"] = "˜", ["hatwidest"] = "ˆ", ["tildewidest"] = "˜",
            ["alpha"] = "α", ["beta"] = "β", ["gamma"] = "γ", ["delta"] = "δ", ["epsilon"] = "ϵ", ["epsilon1"] = "ε", ["zeta"] = "ζ", ["eta"] = "η",
            ["theta"] = "θ", ["theta1"] = "ϑ", ["iota"] = "ι", ["kappa"] = "κ", ["lambda"] = "λ", ["mu"] = "μ", ["nu"] = "ν", ["xi"] = "ξ", ["omicron"] = "ο",
            ["pi"] = "π", ["pi1"] = "ϖ", ["rho"] = "ρ", ["rho1"] = "ϱ", ["sigma"] = "σ", ["sigma1"] = "ς", ["tau"] = "τ", ["upsilon"] = "υ", ["phi"] = "ϕ",
            ["phi1"] = "φ", ["chi"] = "χ", ["psi"] = "ψ", ["omega"] = "ω", ["varepsilon"] = "ε", ["vartheta"] = "ϑ", ["varpi"] = "ϖ", ["varrho"] = "ϱ",
            ["varsigma"] = "ς", ["varphi"] = "φ", ["epsilonvariant"] = "ε", ["thetavariant"] = "ϑ", ["phivariant"] = "φ", ["pivariant"] = "ϖ",
            ["rhovariant"] = "ϱ", ["sigmavariant"] = "ς", ["kappavariant"] = "ϰ",
            ["Alpha"] = "Α", ["Beta"] = "Β", ["Gamma"] = "Γ", ["Delta"] = "Δ", ["Epsilon"] = "Ε", ["Zeta"] = "Ζ", ["Eta"] = "Η", ["Theta"] = "Θ", ["Iota"] = "Ι",
            ["Kappa"] = "Κ", ["Lambda"] = "Λ", ["Mu"] = "Μ", ["Nu"] = "Ν", ["Xi"] = "Ξ", ["Omicron"] = "Ο", ["Pi"] = "Π", ["Rho"] = "Ρ", ["Sigma"] = "Σ",
            ["Tau"] = "Τ", ["Upsilon"] = "Υ", ["Upsilon1"] = "ϒ", ["Phi"] = "Φ", ["Chi"] = "Χ", ["Psi"] = "Ψ", ["Omega"] = "Ω",
        };
        var accents = new Dictionary<string, string>
        {
            ["acute"] = "́", ["grave"] = "̀", ["circumflex"] = "̂", ["tilde"] = "̃", ["dieresis"] = "̈", ["ring"] = "̊",
            ["cedilla"] = "̧", ["caron"] = "̌", ["macron"] = "̄", ["breve"] = "̆", ["ogonek"] = "̨", ["dotaccent"] = "̇",
            ["hungarumlaut"] = "̋", ["commaaccent"] = "̦",
        };
        foreach (var letter in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            foreach (var (accent, mark) in accents)
                t[letter + accent] = (letter + mark).Normalize(NormalizationForm.FormC);
        return t;
    }
}
