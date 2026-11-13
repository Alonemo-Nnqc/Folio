using System.Globalization;
using System.Text;
using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Pdf;
using Folio.Core.Translate.Typeset;
using SkiaSharp;

namespace Folio.Core.Translate.Edit;

/// <summary>A paragraph of a page opened for editing (EDIT-01), changed in place: what is not touched stays exactly as
/// drawn. The macOS editor's PDFParagraph (ParagraphEdit.swift), rule for rule.
///
/// The paragraph is a row of atoms: its glyphs as they are (each keeps its font, size, colour and the kerning to its
/// neighbours), the spaces between words, the ends of its lines (a space, nothing between Chinese characters, or a
/// hyphen that breaks a word and shows only where a line ends), its formulas and citations (moved whole), and the
/// characters typed. A character typed is drawn in the font of the text beside it, with a glyph that font already draws
/// on the page; only a character no font of the page has falls back to a system font in the same style.
///
/// Laying it out keeps every line before the first change as it is and chooses where the lines from there break as a
/// whole (as TeX does): each line drawn again costs, lines set looser or tighter than the page's cost more the further
/// they go, a hyphen added costs, a line more than the page had costs a lot. The cheapest way usually keeps the edit in
/// its own line and comes back to the page's own line breaks as soon as it can; from there the lines stay as they are.</summary>
public sealed class PdfParagraph
{
    public enum AtomKind { Char, Space, LineEnd, SoftHyphen, Formula, Typed, TypedSpace }

    /// <summary>Index: into Chars (Char, Space, SoftHyphen) or Formulas (Formula). Line: the page's line it was on (typed:
    /// the line it was typed into). Original: its place in the original row.</summary>
    public readonly record struct Atom(AtomKind Kind, int Index, bool Spaced, string? Typed, int Line, int? Original);

    /// <summary>What the editor holds: kept for undo and redo inside an editing session.</summary>
    public sealed record State(Atom[] Atoms, int[] Dirty);

    public int Page { get; }
    public int Block { get; }
    readonly List<LayoutLine> _lines;
    readonly List<PageChar> _chars;
    readonly List<int> _charLine;
    readonly List<FormulaSpan> _formulas;
    readonly Atom[] _originalAtoms;
    Atom[] _atoms;
    HashSet<int> _dirty = [];
    readonly ContentInterpreter _interpreter;
    public Rect MediaBox { get; }
    readonly double _size, _pitch;
    readonly bool _centered, _justified;
    readonly double _naturalSpace, _typicalSpace, _columnLeft, _columnRight;
    /// <summary>How far the page itself squeezed the spaces of its tightest line (a share of the natural space): a line
    /// set again may be squeezed as far.</summary>
    readonly double _pageShrink;
    readonly Dictionary<int, Dictionary<string, int>> _donors = [];
    /// <summary>How low the paragraph may reach: the top of what is under it in its column (or the page's bottom margin).</summary>
    readonly double _floor;
    readonly Dictionary<string, List<int>> _hyphenationCache = [];

    public PdfParagraph(int page, int block, LayoutBlock layoutBlock, List<FormulaSpan> spans, ContentInterpreter interpreter, Rect mediaBox, double floor)
    {
        Page = page;
        Block = block;
        _interpreter = interpreter;
        MediaBox = mediaBox;
        _floor = floor;
        _lines = layoutBlock.Lines;
        _size = layoutBlock.Size;
        _pitch = layoutBlock.Pitch;
        _centered = layoutBlock.IsCentered;
        // Formula pieces (a citation broken over a line is two pieces), each moved whole.
        var pieces = new List<FormulaSpan>();
        foreach (var span in spans)
        {
            var main = new FormulaSpan
            {
                Rect = span.Rect, Baseline = span.Baseline, Runs = span.Runs, Size = span.Size, Glyphs = span.Glyphs, Links = span.Links,
                Ink = span.Ink, Spaced = span.Spaced, Icons = span.Icons,
            };
            pieces.Add(main);
            pieces.AddRange(span.Continuation);
        }
        _formulas = pieces;
        var pieceGlyphs = pieces.Select(p => p.Glyphs.ToHashSet()).ToList();

        _chars = [];
        _charLine = [];
        var atoms = new List<Atom>();
        for (int li = 0; li < _lines.Count; li++)
        {
            var line = _lines[li];
            var placedPieces = new HashSet<int>();
            foreach (var c in line.Chars)
            {
                int ci = _chars.Count;
                _chars.Add(c);
                _charLine.Add(li);
                if (c.IsSpace)
                {
                    if (atoms.Count == 0 || atoms[^1].Kind != AtomKind.Space) atoms.Add(new Atom(AtomKind.Space, ci, false, null, li, null));
                    continue;
                }
                if (c.Glyphs.Count > 0)
                {
                    int p = pieceGlyphs.FindIndex(g => g.IsSupersetOf(c.Glyphs));
                    if (p >= 0)
                    {
                        if (placedPieces.Add(p)) atoms.Add(new Atom(AtomKind.Formula, p, false, null, li, null));
                        continue;
                    }
                }
                atoms.Add(new Atom(AtomKind.Char, ci, false, null, li, null));
            }
            // Spaces at a line's end belong to the break.
            while (atoms.Count > 0 && atoms[^1].Kind == AtomKind.Space) atoms.RemoveAt(atoms.Count - 1);
            if (li == _lines.Count - 1) continue;
            var nextText = _lines[li + 1].Chars.FirstOrDefault(c => !c.IsSpace)?.Text ?? "";
            char? next = nextText.Length > 0 ? nextText[0] : null;
            string lastText = atoms.Count > 0 && atoms[^1].Kind == AtomKind.Char ? _chars[atoms[^1].Index].Text : "";
            if (atoms.Count >= 2 && atoms[^1].Kind == AtomKind.Char && lastText is "-" or "‐"
                && atoms[^2].Kind == AtomKind.Char && _chars[atoms[^2].Index].Text is { Length: > 0 } before && char.IsLetter(before[^1])
                && next is { } n && char.IsLower(n))
            {
                atoms[^1] = atoms[^1] with { Kind = AtomKind.SoftHyphen };
                atoms.Add(new Atom(AtomKind.LineEnd, -1, false, null, li, null));
            }
            else
            {
                bool cjk = IsCjk(LastRune(lastText)) && IsCjk(next is { } x ? x : null);
                bool dash = lastText is "-" or "–" or "—" or "/";
                atoms.Add(new Atom(AtomKind.LineEnd, -1, !cjk && !dash, null, li, null));
            }
        }
        for (int i = 0; i < atoms.Count; i++) atoms[i] = atoms[i] with { Original = i };
        _originalAtoms = [.. atoms];
        _atoms = [.. atoms];

        // The column: where lines start (the first may be set in) and end.
        var lefts = _lines.Select(l => l.MinX).ToList();
        var rights = _lines.Select(l => l.MaxX).ToList();
        _columnLeft = lefts.Count > 1 ? lefts.Skip(1).Min() : lefts[0];
        _columnRight = rights.Max();
        int full = _lines.Take(_lines.Count - 1).Count(l => l.MaxX >= rights.Max() - _size * 0.6);
        _justified = _lines.Count >= 2 && full >= (_lines.Count - 1) * 0.7 && !_centered;

        // The word spaces as the page sets them: from the end of the word before to the start of the next.
        static List<double> Gaps(LayoutLine line)
        {
            var result = new List<double>();
            var chars = line.Chars;
            for (int k = 0; k < chars.Count; k++)
            {
                if (!chars[k].IsSpace || (k > 0 && chars[k - 1].IsSpace)) continue;
                var before = chars.Take(k).LastOrDefault(c => !c.IsSpace);
                var after = chars.Skip(k + 1).FirstOrDefault(c => !c.IsSpace);
                if (before == null || after == null) continue;
                double gap = after.Rect.MinX - before.Rect.MaxX;
                if (gap > 0) result.Add(gap);
            }
            return result;
        }
        var lastGaps = Gaps(_lines[^1]).OrderBy(g => g).ToList();
        var fullGaps = _lines.Take(_lines.Count - 1).SelectMany(Gaps).OrderBy(g => g).ToList();
        double guess = lastGaps.Count > 0 ? lastGaps[lastGaps.Count / 2] : fullGaps.Count > 0 ? fullGaps[0] : _size * 0.3;
        _naturalSpace = Math.Min(Math.Max(guess, _size * 0.18), _size * 0.45);
        double median = fullGaps.Count > 0 ? fullGaps[fullGaps.Count / 2] : _naturalSpace;
        _typicalSpace = _justified ? Math.Min(Math.Max(median, _naturalSpace), _size * 0.6) : _naturalSpace;
        var means = _lines.Take(_lines.Count - 1).Select(Gaps).Where(g => g.Count > 0).Select(g => g.Average()).ToList();
        _pageShrink = Math.Min(1, Math.Max(0.5, (means.Count > 0 ? means.Min() : _naturalSpace) / _naturalSpace));

        // Glyphs to borrow: every glyph of the page with plain text, by font.
        for (int g = 0; g < interpreter.Glyphs.Count; g++)
        {
            var glyph = interpreter.Glyphs[g];
            if (!glyph.IsVisible || !glyph.Reliable || !glyph.IsHorizontal || glyph.Font < 0 || string.IsNullOrEmpty(glyph.Text)) continue;
            if (!_donors.TryGetValue(glyph.Font, out var byText)) _donors[glyph.Font] = byText = [];
            byText.TryAdd(glyph.Text, g);
            // Text extracted as a compatibility character (a Kangxi radical for 文) draws the ideograph typed.
            var plain = glyph.Text.Normalize(NormalizationForm.FormKC);
            if (plain != glyph.Text) byText.TryAdd(plain, g);
        }
    }

    static Rune? LastRune(string s) => s.Length == 0 ? null : s.EnumerateRunes().Last();
    static bool IsCjk(Rune? rune) => rune is { } r && IsCjk(r.Value);
    static bool IsCjk(char? c) => c is { } x && IsCjk((int)x);
    public static bool IsCjk(int v) => v is >= 0x2E80 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF or >= 0xF900 and <= 0xFAFF or >= 0xFF00 and <= 0xFFEF;

    // Editing

    public int Count => _atoms.Length;
    public bool IsModified => _dirty.Count > 0 && !_atoms.SequenceEqual(_originalAtoms);

    public State Snapshot
    {
        get => new([.. _atoms], [.. _dirty]);
        set { _atoms = [.. value.Atoms]; _dirty = [.. value.Dirty]; _laidOut = null; }
    }

    public string Text(Atom atom) => atom.Kind switch
    {
        AtomKind.Char => _chars[atom.Index].Text,
        AtomKind.Space or AtomKind.TypedSpace => " ",
        AtomKind.LineEnd => atom.Spaced ? " " : "",
        AtomKind.SoftHyphen => "",
        AtomKind.Formula => string.Concat(_chars.Where(c => !c.IsSpace && c.Glyphs.Count > 0 && _formulas[atom.Index].Glyphs.ToHashSet().IsSupersetOf(c.Glyphs)).Select(c => c.Text)),
        AtomKind.Typed => atom.Typed ?? "",
        _ => "",
    };

    public string String(int start, int end)
    {
        start = Math.Clamp(start, 0, Count);
        end = Math.Clamp(end, start, Count);
        var sb = new StringBuilder();
        for (int i = start; i < end; i++) sb.Append(Text(_atoms[i]));
        return sb.ToString();
    }

    public string String() => String(0, Count);

    /// <summary>The text of each atom (what the editor's caret steps over).</summary>
    public List<string> Texts() => _atoms.Select(Text).ToList();

    /// <summary>The atoms showing needle (its first occurrence), for tests and tools.</summary>
    public (int Start, int End)? Find(string needle)
    {
        var offsets = new List<int>();
        var text = new StringBuilder();
        foreach (var atom in _atoms) { offsets.Add(text.Length); text.Append(Text(atom)); }
        int found = text.ToString().IndexOf(needle, StringComparison.Ordinal);
        if (found < 0) return null;
        int lower = found, upper = found + needle.Length;
        int start = offsets.FindIndex(o => o >= lower);
        int end = offsets.FindIndex(o => o >= upper);
        if (start < 0) start = Count;
        if (end < 0) end = Count;
        return (start, Math.Max(start, end));
    }

    /// <summary>The page's lines drawn again by the edit so far.</summary>
    public List<int> RewrittenLines => [.. Layout.Rewritten.OrderBy(l => l)];

    /// <summary>Whether the caret stops before atom index (not inside a line end that shows nothing).</summary>
    public bool IsStop(int index)
    {
        if (index <= 0 || index >= Count) return true;
        var before = _atoms[index - 1];
        return Text(before).Length > 0 || before.Kind is not (AtomKind.LineEnd or AtomKind.SoftHyphen);
    }

    /// <summary>Replaces atoms start..end with text (typed characters take the style of what is beside them).</summary>
    public void Replace(int start, int end, string text)
    {
        start = Math.Clamp(start, 0, Count);
        end = Math.Clamp(end, start, Count);
        var neighbour = start > 0 ? _atoms[start - 1] : start < _atoms.Length ? _atoms[start] : (Atom?)null;
        int line = neighbour?.Line ?? 0;
        for (int i = start; i < end; i++) _dirty.Add(_atoms[i].Line);
        _dirty.Add(line);
        if (start < _atoms.Length) _dirty.Add(_atoms[start].Line);
        var typed = new List<Atom>();
        foreach (var rune in text.EnumerateRunes())
        {
            if (rune.Value is '\n' or '\r') continue;
            typed.Add(rune.Value is ' ' or 0xA0 or '\t'
                ? new Atom(AtomKind.TypedSpace, -1, false, null, line, null)
                : new Atom(AtomKind.Typed, -1, false, rune.ToString(), line, null));
        }
        _atoms = [.. _atoms.Take(start), .. typed, .. _atoms.Skip(end)];
        _laidOut = null;
    }

    /// <summary>How many atoms text becomes.</summary>
    public static int AtomCount(string text) => text.EnumerateRunes().Count(r => r.Value is not ('\n' or '\r'));

    // Layout

    sealed record Placed(int Atom, double X, double Width, bool Visible, bool HyphenAfter = false);
    sealed record Line(double Baseline, List<Placed> Items, bool Untouched, int? Original);
    sealed class Result
    {
        public List<Line> Lines = [];
        public HashSet<int> Rewritten = [];
        public bool Overflows;
    }

    Result? _laidOut;

    Result Layout
    {
        get
        {
            if (_laidOut != null) return _laidOut;
            // As the page sets it; if that runs into what is below, with tighter spaces; then with the lines drawn again
            // a little closer together (never the lines before the change).
            var result = MakeLayout(Math.Min(0.8, _pageShrink * 0.98), _pitch);
            if (ReachesBelowFloor(result)) result = MakeLayout(Math.Min(0.66, _pageShrink * 0.95), _pitch);
            if (ReachesBelowFloor(result) && _dirty.Count > 0 && _dirty.Min() < _lines.Count)
            {
                int first = _dirty.Min();
                int count = result.Lines.Count;
                double room = _lines[first].Baseline - (_floor + _size * 0.3);
                if (count - 1 > first && room > 0)
                {
                    double tighter = Math.Max(_pitch * 0.88, room / (count - 1 - first));
                    if (tighter < _pitch) result = MakeLayout(Math.Min(0.66, _pageShrink * 0.95), tighter);
                }
                result.Overflows = ReachesBelowFloor(result);
            }
            return _laidOut = result;
        }
    }

    bool ReachesBelowFloor(Result result) =>
        result.Lines.Count > _lines.Count && result.Lines[^1].Baseline - _size * 0.25 < _floor;

    /// <summary>Whether the edit runs the paragraph into what is under it (the editor says so).</summary>
    public bool Overflows => Layout.Overflows;

    List<int> OriginalLine(int li) =>
        Enumerable.Range(0, _originalAtoms.Length).Where(i => _originalAtoms[i].Line == li && _originalAtoms[i].Kind != AtomKind.LineEnd).ToList();

    (double X, double Width)? Geometry(Atom atom) => atom.Kind switch
    {
        AtomKind.Char or AtomKind.Space or AtomKind.SoftHyphen => (_chars[atom.Index].Rect.MinX, _chars[atom.Index].Rect.W),
        AtomKind.Formula => (_formulas[atom.Index].Rect.MinX, _formulas[atom.Index].Rect.W),
        AtomKind.LineEnd => (_lines[atom.Line].MaxX, 0),
        _ => null,
    };

    static bool IsGlue(Atom atom) => atom.Kind is AtomKind.Space or AtomKind.TypedSpace or AtomKind.LineEnd;

    double LeftOf(int slot) => slot == 0 ? _lines[0].MinX : slot < _lines.Count ? _lines[slot].MinX : _columnLeft;

    Result MakeLayout(double shrink, double pitch)
    {
        var atoms = _atoms;
        bool tight = pitch < _pitch - 0.001;
        var result = new Result();
        if (_dirty.Count == 0 || atoms.SequenceEqual(_originalAtoms))
        {
            for (int li = 0; li < _lines.Count; li++) result.Lines.Add(new Line(_lines[li].Baseline, OriginalPlaced(li), true, li));
            return result;
        }
        int firstDirty = _dirty.Min();
        for (int li = 0; li < Math.Min(firstDirty, _lines.Count); li++) result.Lines.Add(new Line(_lines[li].Baseline, OriginalPlaced(li), true, li));
        int start = Array.FindIndex(atoms, a => a.Line >= firstDirty);
        if (start < 0) start = atoms.Length;
        var pieces = Pieces(start, atoms);
        int n = pieces.Count;
        double BaselineOf(int slot) => tight ? _lines[Math.Min(firstDirty, _lines.Count - 1)].Baseline - pitch * (slot - firstDirty)
            : slot < _lines.Count ? _lines[slot].Baseline : _lines[^1].Baseline - pitch * (slot - _lines.Count + 1);
        if (n == 0)
        {
            // All of it deleted from here on.
            if (firstDirty < _lines.Count && (start < atoms.Length || firstDirty == 0)) result.Lines.Add(new Line(BaselineOf(firstDirty), [], false, firstDirty));
            for (int li = firstDirty; li < _lines.Count; li++) result.Rewritten.Add(li);
            return result;
        }

        // From atom i on: the page's own atoms, in their order, to the end; and how far they run on in their order.
        var tail = new bool[atoms.Length + 1];
        tail[atoms.Length] = true;
        var run = new int[atoms.Length + 1];
        for (int i = atoms.Length - 1; i >= 0; i--)
        {
            run[i] = -1;
            if (atoms[i].Original is not { } o) continue;
            tail[i] = o == _originalAtoms.Length - (atoms.Length - i) && tail[i + 1];
            run[i] = i + 1 < atoms.Length && atoms[i + 1].Original == o + 1 ? run[i + 1] : i;
        }
        var current = new Dictionary<int, int>();
        for (int i = 0; i < atoms.Length; i++) if (atoms[i].Original is { } o) current[o] = i;
        var content = Enumerable.Range(0, _lines.Count).Select(li => OriginalLine(li).Where(i => !IsGlue(_originalAtoms[i])).ToList()).ToList();
        int FirstAtom(int p) => pieces[p].Atoms.Count > 0 ? pieces[p].Atoms[0] : pieces[p].Hyphen ?? start;
        int LastAtom(int p) => pieces[p].Hyphen ?? (pieces[p].Atoms.Count > 0 ? pieces[p].Atoms[^1] : start);
        bool IsSame(int slot, int p, int b)
        {
            if (tight || slot >= _lines.Count || content[slot].Count == 0) return false;
            if (!current.TryGetValue(content[slot][0], out var cf) || !current.TryGetValue(content[slot][^1], out var cl)) return false;
            return FirstAtom(p) == cf && LastAtom(b - 1) == cl && run[cf] >= cl;
        }
        bool Converges(int p, int slot)
        {
            if (tight || slot >= _lines.Count || content[slot].Count == 0 || !current.TryGetValue(content[slot][0], out var cf)) return false;
            return FirstAtom(p) == cf && tail[cf];
        }

        var widths = new double[n + 1];
        var glues = new double[n + 1];
        var joints = new int[n + 1];
        for (int p = 0; p < n; p++)
        {
            widths[p + 1] = widths[p] + pieces[p].Width;
            glues[p + 1] = glues[p] + pieces[p].Natural;
            joints[p + 1] = joints[p] + (pieces[p].Kind == PieceKind.Cjk ? 1 : 0);
        }
        double BreakWidth(int p)
        {
            if (pieces[p].Hyphen is { } h) return HyphenWidth(h, atoms);
            if (pieces[p].AddsHyphen && pieces[p].Atoms.Count > 0) return StyleFor(pieces[p].Atoms[^1] + 1, atoms).Advance("-");
            return 0;
        }
        double? Cost(int slot, int p, int b)
        {
            if (IsSame(slot, p, b)) return 0;
            bool last = b == n;
            double available = _columnRight - LeftOf(slot);
            double words = widths[b] - widths[p] + (last ? 0 : BreakWidth(b - 1));
            double glue = glues[b] - glues[p + 1];
            double badness = 0;
            if (words + glue * shrink > available + 0.01)
            {
                if (b != p + 1) return null;
                badness = 5000;
            }
            else if (_justified && !last)
            {
                // Against the spaces the page's own lines have: 60 % wider, or 30 % narrower, is as bad as it gets; the
                // joints between CJK characters stretch by a twenty-fifth of an em.
                double spaces = glue / Math.Max(_naturalSpace, 0.01);
                double slack = available - words - spaces * _typicalSpace;
                if (slack > 0)
                {
                    double stretch = spaces * _typicalSpace * 0.6 + (joints[b] - joints[p + 1]) * _size * 0.04;
                    badness = stretch > 0 ? 100 * Math.Pow(Math.Min(slack / stretch, 5), 3) : (slack > _size ? 2000 : 0);
                }
                else if (spaces > 0) badness = 100 * Math.Pow(Math.Min(-slack / (spaces * _typicalSpace * 0.3), 5), 3);
            }
            else
            {
                double slack = available - words - glue;
                // Ragged or centred lines: fuller lines first.
                if (!_justified && !last && slack > 0) badness = 20 * Math.Pow(slack / Math.Max(available, 1), 2);
                else if (slack < 0 && glue > 0) badness = 100 * Math.Pow(-slack / (glue * 0.34), 3);
            }
            double penalty = 150;
            if (slot >= _lines.Count) penalty += 400;
            if (!last)
            {
                if (pieces[b - 1].AddsHyphen) penalty += 50;
                else if (pieces[b - 1].Hyphen != null) penalty += 10;
            }
            return penalty + badness;
        }

        // Lines, best first: cheapest[p, k] is the least the pieces before p cost set in k lines from the first changed.
        double total = Math.Max(widths[n] + glues[n], 1);
        int limit = Math.Max(_lines.Count - firstDirty, (int)(total / Math.Max(_columnRight - _columnLeft, 1) * 1.4) + 2) + 2;
        var choice = new List<(int Slot, int From, int To)>();
        int? converged = null;
        while (choice.Count == 0)
        {
            var cheapest = new double[n + 1, limit + 1];
            var from = new int[n + 1, limit + 1];
            for (int p = 0; p <= n; p++) for (int k = 0; k <= limit; k++) { cheapest[p, k] = double.PositiveInfinity; from[p, k] = -1; }
            cheapest[0, 0] = 0;
            (int P, int K, double Cost, bool Converged)? finish = null;
            for (int p = 0; p <= n; p++)
                for (int k = 0; k <= limit; k++)
                {
                    if (double.IsPositiveInfinity(cheapest[p, k])) continue;
                    int slot = firstDirty + k;
                    double sofar = cheapest[p, k];
                    if (p == n)
                    {
                        double left = slot < _lines.Count ? (_lines.Count - slot) * 5 : 0;
                        if (sofar + left < (finish?.Cost ?? double.PositiveInfinity)) finish = (p, k, sofar + left, false);
                        continue;
                    }
                    if (Converges(p, slot))
                    {
                        if (sofar < (finish?.Cost ?? double.PositiveInfinity)) finish = (p, k, sofar, true);
                        continue;
                    }
                    if (k >= limit) continue;
                    for (int b = p + 1; b <= n; b++)
                    {
                        if (Cost(slot, p, b) is not { } c) break;
                        if (sofar + c < cheapest[b, k + 1])
                        {
                            cheapest[b, k + 1] = sofar + c;
                            from[b, k + 1] = p;
                        }
                    }
                }
            if (finish is { } f)
            {
                int p = f.P, k = f.K;
                while (k > 0)
                {
                    int a = from[p, k];
                    choice.Insert(0, (firstDirty + k - 1, a, p));
                    p = a;
                    k--;
                }
                if (f.Converged) converged = firstDirty + f.K;
                if (choice.Count == 0) break;
            }
            else
            {
                if (limit >= n + 1) break;
                limit = n + 1;
            }
        }

        for (int index = 0; index < choice.Count; index++)
        {
            var line = choice[index];
            int next = index + 1 < choice.Count ? FirstAtom(choice[index + 1].From) : converged != null ? FirstAtom(line.To) : atoms.Length;
            if (IsSame(line.Slot, line.From, line.To))
                result.Lines.Add(new Line(BaselineOf(line.Slot), OriginalPlaced(line.Slot), true, line.Slot));
            else
            {
                var items = Place(pieces, line.From, line.To, line.Slot, line.To == n, next, atoms);
                result.Lines.Add(new Line(BaselineOf(line.Slot), items, false, line.Slot < _lines.Count ? line.Slot : null));
                if (line.Slot < _lines.Count) result.Rewritten.Add(line.Slot);
            }
        }
        if (converged is { } c0)
        {
            for (int li = c0; li < _lines.Count; li++) result.Lines.Add(new Line(_lines[li].Baseline, OriginalPlaced(li), true, li));
        }
        else
        {
            // Lines of the page left empty go.
            int used = (choice.Count > 0 ? choice[^1].Slot : firstDirty - 1) + 1;
            for (int li = used; li < _lines.Count; li++) result.Rewritten.Add(li);
        }
        return result;
    }

    /// <summary>The page's line li as it is drawn.</summary>
    List<Placed> OriginalPlaced(int li)
    {
        var ids = OriginalLine(li).ToHashSet();
        var result = new List<Placed>();
        for (int i = 0; i < _atoms.Length; i++)
        {
            if (_atoms[i].Original is not { } o || !ids.Contains(o) || Geometry(_atoms[i]) is not { } g) continue;
            result.Add(new Placed(i, g.X, g.Width, _atoms[i].Kind is not (AtomKind.Space or AtomKind.LineEnd)));
        }
        return result;
    }

    /// <summary>How far atom i reaches to where the next atom starts: as on the page when the two stood so there, else
    /// its advance.</summary>
    double Advance(Atom[] atoms, int i)
    {
        var atom = atoms[i];
        if (i + 1 < atoms.Length && atom.Original is { } a && atoms[i + 1].Original is { } b && b == a + 1
            && _originalAtoms[a].Line == _originalAtoms[b].Line && Geometry(atom) is { } ga && Geometry(atoms[i + 1]) is { } gb)
            return gb.X - ga.X;
        return WidthOf(atoms, i);
    }

    double WidthOf(Atom[] atoms, int i) => atoms[i].Kind switch
    {
        AtomKind.Typed => StyleFor(i, atoms).Advance(atoms[i].Typed ?? ""),
        AtomKind.TypedSpace or AtomKind.Space or AtomKind.LineEnd => 0,
        _ => Geometry(atoms[i])?.Width ?? 0,
    };

    enum PieceKind { Word, Cjk, Part }

    /// <summary>A word, or a part of one where the line may break (after a soft hyphen of the page, a hyphen of its own,
    /// a place the hyphenation patterns allow), or a CJK character; and the glue before it.</summary>
    sealed class Piece
    {
        public List<int> Atoms = [];
        public double Width;
        /// <summary>The glue atom that takes the gap's width.</summary>
        public int? GlueBefore;
        /// <summary>The gap's natural width.</summary>
        public double Natural;
        /// <summary>A soft hyphen of the page ending it: drawn when the line breaks here.</summary>
        public int? Hyphen;
        /// <summary>A hyphenation place: a hyphen is drawn when the line breaks here.</summary>
        public bool AddsHyphen;
        public PieceKind Kind = PieceKind.Word;
    }

    /// <summary>Punctuation a line never starts with, and punctuation it never ends with.</summary>
    static readonly HashSet<string> Closing = ["，", "。", "、", "；", "：", "？", "！", "）", "」", "』", "】", "〕", "〉", "》", "”", "’", "…", "·", "％",
                                               ",", ".", ";", ":", "?", "!", ")", "]", "}", "%", "'", "”"];
    static readonly HashSet<string> Opening = ["（", "「", "『", "【", "〔", "〈", "《", "“", "‘", "(", "[", "{", "“"];

    List<Piece> Pieces(int start, Atom[] atoms)
    {
        var pieces = new List<Piece>();
        int i = start;
        int? pendingGlue = null;
        double pendingNatural = 0;
        bool afterSoftHyphen = false;
        while (i < atoms.Length)
        {
            var atom = atoms[i];
            if (IsGlue(atom))
            {
                if (pendingGlue == null || pendingNatural == 0)
                {
                    pendingGlue = i;
                    pendingNatural = atom.Kind == AtomKind.LineEnd ? (atom.Spaced ? _naturalSpace : 0) : _naturalSpace;
                }
                afterSoftHyphen = false;
                i++;
                continue;
            }
            // A word: up to glue, a soft hyphen, or a CJK character.
            var word = new List<int>();
            int? hyphen = null;
            int k = i;
            bool cjk = false;
            while (k < atoms.Length && !IsGlue(atoms[k]))
            {
                if (atoms[k].Kind == AtomKind.SoftHyphen) { hyphen = k; k++; break; }
                var t = Text(atoms[k]);
                bool isCjk = t.Length > 0 && IsCjk(t.EnumerateRunes().First().Value);
                // A line may break before or after a CJK character, but not before closing punctuation nor after opening.
                if (word.Count > 0)
                {
                    var previous = Text(atoms[word[^1]]);
                    if ((isCjk || IsCjk(LastRune(previous))) && !Closing.Contains(t) && !Opening.Contains(previous)) break;
                }
                word.Add(k);
                k++;
                if (isCjk) cjk = true;
            }
            bool joined = pendingGlue == null && pieces.Count > 0;
            var kind = afterSoftHyphen ? PieceKind.Part : joined ? PieceKind.Cjk : PieceKind.Word;
            double natural = pieces.Count == 0 || pendingGlue == null ? 0 : pendingNatural;
            // Where else the word may break.
            var bounds = new SortedSet<int> { 0, word.Count };
            if (!cjk) foreach (var cut in Breaks(word, atoms)) bounds.Add(cut);
            var list = bounds.ToList();
            for (int m = 0; m + 1 < list.Count; m++)
            {
                int a = list[m], b = list[m + 1];
                var part = word.GetRange(a, b - a);
                double w = 0;
                foreach (var x in part) w += x + 1 < atoms.Length && !IsGlue(atoms[x + 1]) ? Advance(atoms, x) : WidthOf(atoms, x);
                bool isLast = b == word.Count;
                var piece = new Piece
                {
                    Atoms = part, Width = w, GlueBefore = m == 0 ? pendingGlue : null, Natural = m == 0 ? natural : 0,
                    Hyphen = isLast ? hyphen : null, Kind = m == 0 ? kind : PieceKind.Part,
                };
                // A break after a hyphen of the word adds none.
                if (!isLast && part.Count > 0 && Text(atoms[part[^1]]) is not ("-" or "‐")) piece.AddsHyphen = true;
                pieces.Add(piece);
            }
            if (word.Count == 0 && hyphen != null)
                pieces.Add(new Piece { GlueBefore = pendingGlue, Natural = natural, Hyphen = hyphen, Kind = kind });
            afterSoftHyphen = hyphen != null;
            pendingGlue = null;
            pendingNatural = 0;
            i = k;
        }
        return pieces;
    }

    /// <summary>Where a word may break besides its glue: after a hyphen of its own between letters ("learning-|based"),
    /// and in a run of five Latin letters or more where the hyphenation patterns allow.</summary>
    List<int> Breaks(List<int> word, Atom[] atoms)
    {
        var cuts = new List<int>();
        if (word.Count < 4) return cuts;
        var texts = word.Select(w => Text(atoms[w])).ToList();
        bool IsLetter(int n) => n >= 0 && n < texts.Count && texts[n].Length == 1 && char.IsLetter(texts[n][0]) && texts[n][0] < 0x250;
        for (int at = 2; at < word.Count; at++)
            if (texts[at - 1] is "-" or "‐" && IsLetter(at - 2) && IsLetter(at)) cuts.Add(at);
        int n0 = 0;
        while (n0 < word.Count)
        {
            if (!IsLetter(n0)) { n0++; continue; }
            int end = n0;
            while (end < word.Count && IsLetter(end)) end++;
            if (end - n0 >= 5)
            {
                var runText = string.Concat(texts.Skip(n0).Take(end - n0));
                if (!_hyphenationCache.TryGetValue(runText, out var points)) _hyphenationCache[runText] = points = Hyphenation.Points(runText);
                cuts.AddRange(points.Select(p => p + n0));
            }
            n0 = end;
        }
        return cuts;
    }

    /// <summary>The items of the line slot set from pieces from..to, and the glue after it up to next (where the next
    /// line starts).</summary>
    List<Placed> Place(List<Piece> pieces, int fromPiece, int toPiece, int slot, bool last, int next, Atom[] atoms)
    {
        double left = LeftOf(slot), right = _columnRight, available = right - left;
        var line = pieces.GetRange(fromPiece, toPiece - fromPiece);
        if (line.Count == 0) return [];
        var end = line[^1];
        bool breaksAtHyphen = !last && end.Hyphen != null;
        bool addsHyphen = !last && end.AddsHyphen && end.Hyphen == null;
        double hyphenAdvance = addsHyphen ? StyleFor((end.Atoms.Count > 0 ? end.Atoms[^1] : 0) + 1, atoms).Advance("-") : 0;
        double natural = line.Select((p, k) => (k == 0 ? 0 : p.Natural) + p.Width).Sum()
            + (breaksAtHyphen ? HyphenWidth(end.Hyphen!.Value, atoms) : 0) + hyphenAdvance;
        double extra = 0;
        if (_justified && !last || natural > available + 0.01) extra = available - natural;
        // Stretching, spaces and the joints between CJK characters share it as they can; squeezing, spaces alone.
        var gaps = line.Skip(1).ToList();
        var weight = gaps.Select(g => g.Natural > 0 ? g.Natural * 0.6 : (g.Kind == PieceKind.Cjk && extra > 0 ? _size * 0.1 : 0)).ToList();
        if (weight.All(w => w == 0)) weight = gaps.Select(g => g.Kind == PieceKind.Cjk ? 1.0 : 0).ToList();
        double weightSum = weight.Sum();
        if (weightSum == 0) extra = 0;
        double x = left;
        if (_centered) x = _columnLeft + (right - _columnLeft - natural) / 2;
        var items = new List<Placed>();
        int? previousEnd = null;
        for (int n = 0; n < line.Count; n++)
        {
            var piece = line[n];
            int first = piece.Atoms.Count > 0 ? piece.Atoms[0] : piece.Hyphen ?? 0;
            if (n > 0)
            {
                double gap = piece.Natural + (weightSum > 0 ? extra * weight[n - 1] / weightSum : 0);
                // The glue between the pieces: the one taking the gap, the others with none.
                if (previousEnd is { } p)
                    for (int g = p + 1; g < first; g++) items.Add(new Placed(g, x, g == piece.GlueBefore ? Math.Max(gap, 0) : 0, false));
                x += gap;
            }
            for (int m = 0; m < piece.Atoms.Count; m++)
            {
                int a = piece.Atoms[m];
                double w = m + 1 < piece.Atoms.Count || a + 1 < atoms.Length && !IsGlue(atoms[a + 1]) ? Advance(atoms, a) : WidthOf(atoms, a);
                items.Add(new Placed(a, x, WidthOf(atoms, a), true, addsHyphen && n == line.Count - 1 && m == piece.Atoms.Count - 1));
                x += w;
            }
            if (piece.Hyphen is { } h)
            {
                bool shown = breaksAtHyphen && n == line.Count - 1;
                items.Add(new Placed(h, x, shown ? HyphenWidth(h, atoms) : 0, shown));
                if (shown) x += HyphenWidth(h, atoms);
            }
            previousEnd = piece.Hyphen ?? (piece.Atoms.Count > 0 ? piece.Atoms[^1] : previousEnd);
        }
        if (addsHyphen) x += hyphenAdvance;
        // The glue at the break belongs to this line (the caret can stand after it at the line's end).
        if (previousEnd is { } pe) for (int g = pe + 1; g < next; g++) items.Add(new Placed(g, x, 0, false));
        return items;
    }

    double HyphenWidth(int i, Atom[] atoms) => atoms[i].Kind == AtomKind.SoftHyphen ? _chars[atoms[i].Index].Rect.W : 0;

    // Typed characters

    /// <summary>How a typed character is drawn: the glyph it borrows (font, code, width) or the system font standing in,
    /// at the size, slant, colour and height of the text beside it.</summary>
    sealed class Style(Glyph context, double rise, PdfParagraph paragraph)
    {
        public Glyph Context => context;
        public double Rise => rise;
        public Glyph? GlyphFor(string text) => paragraph.Borrow(text, context);

        public double Advance(string text)
        {
            if (GlyphFor(text) is { } g) return g.Width * Math.Sqrt(context.Matrix.A * context.Matrix.A + context.Matrix.B * context.Matrix.B);
            var face = paragraph.FallbackFace(context, text);
            using var font = new SKFont(face.Typeface, (float)FontSize(context)) { Subpixel = true, LinearMetrics = true };
            return font.MeasureText(text);
        }
    }

    static double FontSize(Glyph g) => Math.Max(Math.Sqrt(g.Matrix.C * g.Matrix.C + g.Matrix.D * g.Matrix.D), 1);

    /// <summary>The style of the typed atom i: from the nearest drawn character before it, else after it.</summary>
    Style StyleFor(int i, Atom[] atoms)
    {
        (Glyph, double)? ContextGlyph(int k)
        {
            if (k < 0 || k >= atoms.Length || atoms[k].Kind is not (AtomKind.Char or AtomKind.SoftHyphen)) return null;
            var c = _chars[atoms[k].Index];
            if (c.Glyphs.Count == 0 || c.Glyphs[0] >= _interpreter.Glyphs.Count) return null;
            var glyph = _interpreter.Glyphs[c.Glyphs[0]];
            return (glyph, glyph.Origin.Y - _lines[_charLine[atoms[k].Index]].Baseline);
        }
        for (int k = i - 1; k >= 0; k--) if (ContextGlyph(k) is { } found) return new Style(found.Item1, found.Item2, this);
        for (int k = i + 1; k < atoms.Length; k++) if (ContextGlyph(k) is { } found) return new Style(found.Item1, found.Item2, this);
        // Nothing to go by (all of it typed anew): the paragraph's first glyph.
        var first = _chars.FirstOrDefault(c => c.Glyphs.Count > 0 && c.Glyphs[0] < _interpreter.Glyphs.Count);
        var g = first != null ? _interpreter.Glyphs[first.Glyphs[0]]
            : new Glyph { Run = -1, Code = 0, Length = 1, Font = -1, Matrix = Affine.Scale(_size, _size), Width = 0.5, Size = _size, Color = new RGBColor(0, 0, 0) };
        return new Style(g, 0, this);
    }

    static Glyph Copy(Glyph g) => new()
    {
        Run = g.Run, Code = g.Code, Length = g.Length, Font = g.Font, Matrix = g.Matrix, Width = g.Width, Size = g.Size, Text = g.Text,
        Reliable = g.Reliable, RenderMode = g.RenderMode, Color = g.Color, Element = g.Element, Offset = g.Offset, Adjustment = g.Adjustment,
        Depth = g.Depth, IsClipped = g.IsClipped,
    };

    /// <summary>A glyph drawing text in context's font (else a font of the page in the same style), sized and placed like it.</summary>
    Glyph? Borrow(string text, Glyph context)
    {
        Glyph Make(int font, int code, int length, double width)
        {
            var g = Copy(context);
            g.Font = font; g.Code = code; g.Length = length; g.Width = width; g.Text = text; g.Reliable = true; g.Run = -1;
            return g;
        }
        if (context.Font < 0 || context.Font >= _interpreter.Fonts.Count) return null;
        if (_donors.TryGetValue(context.Font, out var own) && own.TryGetValue(text, out var d))
        {
            var donor = _interpreter.Glyphs[d];
            return Make(context.Font, donor.Code, donor.Length, donor.Width);
        }
        // A whole font (not a subset): any character its tables name.
        var metrics = _interpreter.Fonts[context.Font];
        if (!IsSubset(metrics.Dict) && metrics.Encoding.Code(text) is { } code)
            return Make(context.Font, code, metrics.Dict.Name("Subtype") == "Type0" ? 2 : 1, metrics.Width(code));
        // Another font of the page in the same style that has it.
        var info = metrics.Info;
        foreach (var (font, glyphs) in _donors)
        {
            if (font == context.Font) continue;
            var other = _interpreter.Fonts[font].Info;
            if (other.IsBold != info.IsBold || other.IsItalic != info.IsItalic || other.IsSerif != info.IsSerif || other.IsMonospace != info.IsMonospace) continue;
            if (!glyphs.TryGetValue(text, out var od)) continue;
            var donor = _interpreter.Glyphs[od];
            return Make(font, donor.Code, donor.Length, donor.Width);
        }
        return null;
    }

    static bool IsSubset(PDict dict) => dict.Name("BaseFont") is not { } name || System.Text.RegularExpressions.Regex.IsMatch(name, "^[A-Z]{6}\\+");

    /// <summary>The system font standing in for a character no font of the page has: the context's weight and family kind
    /// (serif or sans; SimSun or Microsoft YaHei for CJK).</summary>
    FontCatalog.Face FallbackFace(Glyph context, string text)
    {
        var info = context.Font >= 0 && context.Font < _interpreter.Fonts.Count ? _interpreter.Fonts[context.Font].Info : FontInfo.Unknown;
        int codepoint = text.Length > 0 ? text.EnumerateRunes().First().Value : 'a';
        if (IsCjk(codepoint)) return FontCatalog.Script("zh", info.IsBold, info.IsSerif) ?? FontCatalog.Fallback(codepoint, info.IsBold, "zh");
        var latin = FontCatalog.Latin(info.IsSerif, info.IsBold);
        return latin.Typeface.ContainsGlyph(codepoint) ? latin : FontCatalog.Fallback(codepoint, info.IsBold, "en");
    }

    // Drawing

    public sealed record FallbackRun(string Text, Pt Origin, FontCatalog.Face Face, double Size, RGBColor Color);

    /// <summary>What the edited lines draw: glyphs of the page (moved, or borrowed for typed characters), formulas moved
    /// whole, characters in a system font, the page's lines they replace and where the links of the edited lines go.</summary>
    public sealed class Drawing
    {
        public List<Glyph> Glyphs = [];
        public List<Transplant> Transplants = [];
        public List<FallbackRun> Fallback = [];
        public HashSet<int> Rewritten = [];
        public Dictionary<int, List<Rect>> LinkPlaces = [];
        /// <summary>The page's lines (as rectangles) and the lines set again: what a preview paints over.</summary>
        public List<Rect> Paint = [];
    }

    public Drawing Draw()
    {
        var result = Layout;
        var atoms = _atoms;
        var drawing = new Drawing { Rewritten = [.. result.Rewritten] };
        var linkRects = new Dictionary<int, List<Rect>>();
        foreach (var line in result.Lines.Where(l => !l.Untouched))
        {
            foreach (var item in line.Items.Where(i => i.Visible))
            {
                var atom = atoms[item.Atom];
                switch (atom.Kind)
                {
                    case AtomKind.Char or AtomKind.SoftHyphen:
                    {
                        var c = _chars[atom.Index];
                        double dx = item.X - c.Rect.MinX, dy = line.Baseline - _lines[_charLine[atom.Index]].Baseline;
                        foreach (var g in c.Glyphs.Where(g => g < _interpreter.Glyphs.Count))
                        {
                            var glyph = Copy(_interpreter.Glyphs[g]);
                            glyph.Matrix = glyph.Matrix.Concatenating(Affine.Translation(dx, dy));
                            drawing.Glyphs.Add(glyph);
                        }
                        if (c.Link is { } link)
                        {
                            if (!linkRects.TryGetValue(link, out var list)) linkRects[link] = list = [];
                            list.Add(c.Rect.Offset(dx, dy));
                        }
                        if (item.HyphenAfter) AppendHyphen(item, line.Baseline, atoms, drawing);
                        break;
                    }
                    case AtomKind.Formula:
                    {
                        var span = _formulas[atom.Index];
                        double dx = item.X - span.Rect.MinX, dy = line.Baseline - span.Baseline;
                        // Moved or not, a formula of a line drawn again is drawn again whole (with its bars and pictures).
                        drawing.Transplants.Add(new Transplant(span, new Pt(item.X, line.Baseline), 1));
                        foreach (var l in span.Links)
                        {
                            if (!linkRects.TryGetValue(l.Link, out var list)) linkRects[l.Link] = list = [];
                            list.Add(l.Rect.Offset(dx, dy));
                        }
                        break;
                    }
                    case AtomKind.Typed:
                    {
                        var style = StyleFor(item.Atom, atoms);
                        var origin = new Pt(item.X, line.Baseline + style.Rise);
                        var text = atom.Typed ?? "";
                        if (style.GlyphFor(text) is { } glyph)
                        {
                            glyph.Matrix = glyph.Matrix with { Tx = origin.X, Ty = origin.Y };
                            drawing.Glyphs.Add(glyph);
                        }
                        else drawing.Fallback.Add(new FallbackRun(text, origin, FallbackFace(style.Context, text), FontSize(style.Context), style.Context.Color));
                        if (item.HyphenAfter) AppendHyphen(item, line.Baseline, atoms, drawing);
                        break;
                    }
                }
            }
        }
        // Links of the edited lines: where their words went, and where they stay in the lines left alone.
        foreach (var li in result.Rewritten.Where(l => l < _lines.Count))
            foreach (var c in _lines[li].Chars)
                if (c.Link is { } link && !linkRects.ContainsKey(link)) linkRects[link] = [];
        foreach (var (link, list) in linkRects)
            foreach (var line in result.Lines.Where(l => l.Untouched && l.Original != null))
                foreach (var c in _lines[line.Original!.Value].Chars.Where(c => c.Link == link)) list.Add(c.Rect);
        drawing.LinkPlaces = linkRects.ToDictionary(kv => kv.Key, kv => MergedRects(kv.Value));
        // What a preview paints: where the old glyphs were, and where the new ones are.
        drawing.Paint.AddRange(Covers(drawing));
        drawing.Paint.AddRange(drawing.Glyphs.Select(g => g.Box.InsetBy(-0.5, -0.5)));
        drawing.Paint.AddRange(drawing.Transplants.Select(t => t.Formula.Rect.Offset(t.Origin.X - t.Formula.Rect.MinX, t.Origin.Y - t.Formula.Baseline).InsetBy(-0.5, -0.5)));
        drawing.Paint.AddRange(drawing.Fallback.Select(f => Rect.FromCorners(f.Origin.X - 0.5, f.Origin.Y - f.Size * 0.3, f.Origin.X + f.Size * 1.2, f.Origin.Y + f.Size)));
        return drawing;
    }

    /// <summary>The hyphen of a word broken by hyphenation, in the word's font, right after its last letter.</summary>
    void AppendHyphen(Placed item, double baseline, Atom[] atoms, Drawing drawing)
    {
        var style = StyleFor(item.Atom + 1, atoms);
        var origin = new Pt(item.X + item.Width, baseline + style.Rise);
        if ((style.GlyphFor("-") ?? style.GlyphFor("‐")) is { } glyph)
        {
            glyph.Matrix = glyph.Matrix with { Tx = origin.X, Ty = origin.Y };
            drawing.Glyphs.Add(glyph);
        }
        else drawing.Fallback.Add(new FallbackRun("-", origin, FallbackFace(style.Context, "-"), FontSize(style.Context), style.Context.Color));
    }

    /// <summary>Rectangles of one line merged (a link over several words is one place per line).</summary>
    static List<Rect> MergedRects(List<Rect> rects)
    {
        var result = new List<Rect>();
        foreach (var r in rects.OrderByDescending(r => r.MinY).ThenBy(r => r.MinX))
        {
            if (result.Count > 0 && Math.Abs(result[^1].MidY - r.MidY) < r.H * 0.5 && r.MinX - result[^1].MaxX < r.H) result[^1] = result[^1].Union(r);
            else result.Add(r);
        }
        return result;
    }

    /// <summary>Content drawing glyphs with their fonts (named by fontName).</summary>
    public static string Content(List<Glyph> glyphs, Func<int, string> fontName)
    {
        if (glyphs.Count == 0) return "";
        var sb = new StringBuilder("BT 0 Tc 0 Tw 100 Tz 0 Ts\n");
        int font = -1, mode = -1;
        RGBColor? color = null;
        foreach (var g in glyphs.Where(g => g.Font >= 0))
        {
            if (g.Font != font) { font = g.Font; sb.Append('/').Append(fontName(font)).Append(" 1 Tf\n"); }
            if (g.Color != color)
            {
                color = g.Color;
                var c = $"{PdfValue.Format(g.Color.R)} {PdfValue.Format(g.Color.G)} {PdfValue.Format(g.Color.B)}";
                sb.Append(c).Append(" rg ").Append(c).Append(" RG\n");
            }
            int render = Math.Min(g.RenderMode, 2);
            if (render != mode) { mode = render; sb.Append(render.ToString(CultureInfo.InvariantCulture)).Append(" Tr\n"); }
            var code = new StringBuilder();
            for (int k = g.Length - 1; k >= 0; k--) code.Append(((g.Code >> (8 * k)) & 0xFF).ToString("X2", CultureInfo.InvariantCulture));
            var m = g.Matrix;
            sb.Append(string.Join(' ', new[] { m.A, m.B, m.C, m.D, m.Tx, m.Ty }.Select(PdfValue.Format))).Append(" Tm <").Append(code).Append("> Tj\n");
        }
        return sb.Append("ET\n").ToString();
    }

    // For the editor's view (page space)

    /// <summary>A line as it is now: its baseline, top and bottom, and the caret positions in it (atom index, x).</summary>
    public sealed record ShownLine(double Baseline, double Top, double Bottom, List<(int Index, double X)> Stops);

    public List<ShownLine> ShownLines()
    {
        var shown = new List<ShownLine>();
        foreach (var line in Layout.Lines)
        {
            var stops = line.Items.Select(i => (i.Atom, i.X)).ToList();
            if (line.Items.Count > 0) stops.Add((line.Items[^1].Atom + 1, line.Items[^1].X + line.Items[^1].Width));
            shown.Add(new ShownLine(line.Baseline, line.Baseline + _size * 0.92, line.Baseline - _size * 0.28, stops));
        }
        if (shown.Count == 0)
        {
            double left = _lines.Count > 0 ? _lines[0].MinX : _columnLeft, baseline = _lines.Count > 0 ? _lines[0].Baseline : 0;
            shown.Add(new ShownLine(baseline, baseline + _size * 0.92, baseline - _size * 0.28, [(0, left)]));
        }
        return shown;
    }

    /// <summary>The area the paragraph covers now (page space).</summary>
    public Rect Bounds
    {
        get
        {
            var shown = ShownLines();
            double top = shown.Max(l => l.Top), bottom = shown.Min(l => l.Bottom);
            return Rect.FromCorners(Math.Min(_columnLeft, _lines.Count > 0 ? _lines[0].MinX : _columnLeft), bottom, _columnRight, top);
        }
    }

    /// <summary>Where the glyphs of the page's lines drawn again are (they are covered while editing and taken out when
    /// it is written).</summary>
    public List<Rect> Covers(Drawing drawing)
    {
        var cover = new List<Rect>();
        var moved = drawing.Transplants.Select(t => t.Formula).ToHashSet();
        foreach (var li in drawing.Rewritten.Where(l => l < _lines.Count))
        {
            var line = _lines[li];
            foreach (var c in line.Chars.Where(c => !c.IsSpace && c.Glyphs.Count > 0))
            {
                var box = c.Glyphs.Where(g => g < _interpreter.Glyphs.Count).Select(g => _interpreter.Glyphs[g].Box).Aggregate(c.Rect, (r, b) => r.Union(b));
                cover.Add(box.InsetBy(-0.4, -0.4));
            }
            foreach (var f in _formulas.Where(f => Math.Abs(f.Baseline - line.Baseline) < line.Size))
                cover.Add((f.Ink.IsNull ? f.Rect : f.Rect.Union(f.Ink)).InsetBy(-0.5, -0.5));
        }
        return cover;
    }

    internal ContentInterpreter Interpreter => _interpreter;
    internal List<LayoutLine> Lines => _lines;
}
