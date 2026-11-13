using System.Reflection;

namespace Folio.Core.Translate.Edit;

/// <summary>Where English words may be hyphenated (EDIT-01): Liang's algorithm with TeX's US English patterns
/// (Resources/hyph-en-us.txt), as the macOS editor asks the system's hyphenation dictionary.</summary>
public static class Hyphenation
{
    static readonly Lazy<(Dictionary<string, byte[]> Patterns, Dictionary<string, int[]> Exceptions, int Longest)> Table = new(Load);

    static (Dictionary<string, byte[]>, Dictionary<string, int[]>, int) Load()
    {
        var patterns = new Dictionary<string, byte[]>();
        var exceptions = new Dictionary<string, int[]>();
        int longest = 0;
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("hyph-en-us.txt");
        if (stream == null) return (patterns, exceptions, 0);
        using var reader = new StreamReader(stream);
        while (reader.ReadLine() is { } raw)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line[0] == '%') continue;
            if (line.Contains('-'))
            {
                var points = new List<int>();
                int letters = 0;
                foreach (var c in line) { if (c == '-') points.Add(letters); else letters++; }
                exceptions[line.Replace("-", "")] = [.. points];
                continue;
            }
            // "a1b2c": letters "abc", values between them.
            var letters2 = new System.Text.StringBuilder();
            var values = new List<byte> { 0 };
            foreach (var c in line)
            {
                if (char.IsDigit(c)) values[^1] = (byte)(c - '0');
                else { letters2.Append(c); values.Add(0); }
            }
            var key = letters2.ToString();
            patterns[key] = [.. values];
            longest = Math.Max(longest, key.Length);
        }
        return (patterns, exceptions, longest);
    }

    /// <summary>The places (letters before them) a word of Latin letters may be broken at, two letters before and three
    /// after at least.</summary>
    public static List<int> Points(string word)
    {
        var result = new List<int>();
        if (word.Length < 5 || !word.All(c => c is >= 'a' and <= 'z' or >= 'A' and <= 'Z')) return result;
        var (patterns, exceptions, longest) = Table.Value;
        var lower = word.ToLowerInvariant();
        if (exceptions.TryGetValue(lower, out var known)) return known.Where(p => p >= 2 && p <= word.Length - 3).ToList();
        var text = "." + lower + ".";
        var values = new byte[text.Length + 1];
        for (int start = 0; start < text.Length; start++)
            for (int length = 1; length <= Math.Min(longest, text.Length - start); length++)
            {
                if (!patterns.TryGetValue(text.Substring(start, length), out var pattern)) continue;
                for (int k = 0; k < pattern.Length; k++) values[start + k] = Math.Max(values[start + k], pattern[k]);
            }
        // values[i] sits before text[i]; text[i] is word[i - 1].
        for (int i = 2; i <= word.Length - 3; i++)
            if (values[i + 1] % 2 == 1) result.Add(i);
        return result;
    }
}
