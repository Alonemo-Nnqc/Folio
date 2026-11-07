using System.Globalization;
using System.Text;

namespace Folio.Core.Translate.Pdf;

// Port of macos/Packages/FolioCore/Sources/FolioTranslate/PDF/ContentLexer.swift.

/// <summary>An operand of a content-stream operator.</summary>
public abstract record ContentOperand
{
    public sealed record Number(double Value) : ContentOperand;
    public sealed record Name(string Value) : ContentOperand;
    public sealed record Str(byte[] Value) : ContentOperand
    {
        public bool Equals(Str? other) => other != null && Value.AsSpan().SequenceEqual(other.Value);
        public override int GetHashCode() => Value.Length;
    }
    public sealed record Array(List<ContentOperand> Items) : ContentOperand;
    public sealed record Dict(Dictionary<string, ContentOperand> Entries) : ContentOperand;
    public sealed record Bool(bool Value) : ContentOperand;
    public sealed record Null : ContentOperand;

    public static readonly ContentOperand NullValue = new Null();

    public double? AsNumber => this is Number n ? n.Value : null;
    public string? AsName => this is Name n ? n.Value : null;
}

/// <summary>One operator with its operands, and the bytes it occupies in the stream (operands included).</summary>
public sealed record ContentOp(string Name, List<ContentOperand> Operands, int Start, int End, Dictionary<string, ContentOperand>? InlineImage = null)
{
    public int Length => End - Start;
}

/// <summary>Splits a decoded content stream into operators (PDF 32000-1 §7.2, §7.8.2).</summary>
public sealed class ContentLexer
{
    readonly byte[] _bytes;
    int _index;

    public ContentLexer(byte[] data) { _bytes = data; }

    public static List<ContentOp> Parse(byte[] data) => new ContentLexer(data).ParseAll();

    enum Kind { Operand, Keyword, ArrayStart, ArrayEnd, DictStart, DictEnd }
    readonly record struct Token(Kind Kind, ContentOperand? Operand = null, string? Word = null);

    public List<ContentOp> ParseAll()
    {
        var ops = new List<ContentOp>();
        var operands = new List<ContentOperand>();
        int? start = null;
        while (true)
        {
            SkipWhitespace();
            if (_index >= _bytes.Length) break;
            int tokenStart = _index;
            if (NextToken() is not { } token) break;
            start ??= tokenStart;
            switch (token.Kind)
            {
                case Kind.Operand: operands.Add(token.Operand!); break;
                case Kind.ArrayStart: operands.Add(new ContentOperand.Array(ParseArray())); break;
                case Kind.DictStart: operands.Add(new ContentOperand.Dict(ParseDict())); break;
                case Kind.ArrayEnd or Kind.DictEnd: break;
                case Kind.Keyword:
                    var word = token.Word!;
                    if (word == "true") { operands.Add(new ContentOperand.Bool(true)); continue; }
                    if (word == "false") { operands.Add(new ContentOperand.Bool(false)); continue; }
                    if (word == "null") { operands.Add(ContentOperand.NullValue); continue; }
                    if (word == "BI")
                    {
                        var image = ParseInlineImage();
                        ops.Add(new ContentOp("BI", [], start.Value, _index, image));
                    }
                    else ops.Add(new ContentOp(word, operands, start.Value, _index));
                    operands = [];
                    start = null;
                    break;
            }
        }
        return ops;
    }

    public static bool IsWhitespace(byte b) => b is 0x20 or 0x0A or 0x0D or 0x09 or 0x0C or 0x00;
    public static bool IsDelimiter(byte b) => b is (byte)'(' or (byte)')' or (byte)'<' or (byte)'>' or (byte)'[' or (byte)']' or (byte)'{' or (byte)'}' or (byte)'/' or (byte)'%';

    void SkipWhitespace()
    {
        while (_index < _bytes.Length)
        {
            var b = _bytes[_index];
            if (IsWhitespace(b)) _index++;
            else if (b == (byte)'%') { while (_index < _bytes.Length && _bytes[_index] != 0x0A && _bytes[_index] != 0x0D) _index++; }
            else break;
        }
    }

    Token? NextToken()
    {
        if (_index >= _bytes.Length) return null;
        var b = _bytes[_index];
        switch (b)
        {
            case (byte)'[': _index++; return new Token(Kind.ArrayStart);
            case (byte)']': _index++; return new Token(Kind.ArrayEnd);
            case (byte)'<':
                if (_index + 1 < _bytes.Length && _bytes[_index + 1] == (byte)'<') { _index += 2; return new Token(Kind.DictStart); }
                return new Token(Kind.Operand, new ContentOperand.Str(ParseHexString()));
            case (byte)'>': _index += Math.Min(2, _bytes.Length - _index); return new Token(Kind.DictEnd);
            case (byte)'(': return new Token(Kind.Operand, new ContentOperand.Str(ParseLiteralString()));
            case (byte)'/': _index++; return new Token(Kind.Operand, new ContentOperand.Name(ParseName()));
            case (byte)'{' or (byte)'}': _index++; return new Token(Kind.Keyword, Word: ((char)b).ToString());
        }
        if (b is (byte)'+' or (byte)'-' or (byte)'.' or >= 0x30 and <= 0x39)
            if (ParseNumber() is { } number) return new Token(Kind.Operand, new ContentOperand.Number(number));
        int s = _index;
        while (_index < _bytes.Length && !IsWhitespace(_bytes[_index]) && !IsDelimiter(_bytes[_index])) _index++;
        if (_index == s) _index++;
        return new Token(Kind.Keyword, Word: Encoding.UTF8.GetString(_bytes, s, _index - s));
    }

    double? ParseNumber()
    {
        int start = _index;
        bool seenDigit = false;
        if (_bytes[_index] is (byte)'+' or (byte)'-') _index++;
        while (_index < _bytes.Length)
        {
            var c = _bytes[_index];
            if (c is >= 0x30 and <= 0x39) { seenDigit = true; _index++; }
            else if (c is (byte)'.' or (byte)'-') _index++;
            else break;
        }
        if (!seenDigit) { _index = start; return null; }
        var text = Encoding.ASCII.GetString(_bytes, start, _index - start);
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value)) return value;
        // Tolerate "--5" or "1.2.3" from sloppy writers: read the longest valid prefix.
        while (text.Length > 0 && !double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out _)) text = text[..^1];
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : 0;
    }

    string ParseName()
    {
        var output = new List<byte>();
        while (_index < _bytes.Length && !IsWhitespace(_bytes[_index]) && !IsDelimiter(_bytes[_index]))
        {
            if (_bytes[_index] == (byte)'#' && _index + 2 < _bytes.Length
                && byte.TryParse(Encoding.ASCII.GetString(_bytes, _index + 1, 2), NumberStyles.HexNumber, null, out var value))
            {
                output.Add(value);
                _index += 3;
            }
            else output.Add(_bytes[_index++]);
        }
        return Encoding.UTF8.GetString(output.ToArray());
    }

    byte[] ParseLiteralString()
    {
        _index++;
        var output = new List<byte>();
        int depth = 1;
        while (_index < _bytes.Length)
        {
            var c = _bytes[_index++];
            switch (c)
            {
                case (byte)'\\':
                    if (_index >= _bytes.Length) break;
                    var e = _bytes[_index++];
                    switch (e)
                    {
                        case (byte)'n': output.Add(0x0A); break;
                        case (byte)'r': output.Add(0x0D); break;
                        case (byte)'t': output.Add(0x09); break;
                        case (byte)'b': output.Add(0x08); break;
                        case (byte)'f': output.Add(0x0C); break;
                        case 0x0D: if (_index < _bytes.Length && _bytes[_index] == 0x0A) _index++; break;
                        case 0x0A: break;
                        case >= (byte)'0' and <= (byte)'7':
                            int value = e - 0x30;
                            for (int k = 0; k < 2; k++)
                            {
                                if (_index >= _bytes.Length || _bytes[_index] < 0x30 || _bytes[_index] > 0x37) break;
                                value = value * 8 + (_bytes[_index] - 0x30);
                                _index++;
                            }
                            output.Add((byte)(value & 0xFF));
                            break;
                        default: output.Add(e); break;
                    }
                    break;
                case (byte)'(':
                    depth++;
                    output.Add(c);
                    break;
                case (byte)')':
                    depth--;
                    if (depth == 0) return output.ToArray();
                    output.Add(c);
                    break;
                default:
                    output.Add(c);
                    break;
            }
        }
        return output.ToArray();
    }

    byte[] ParseHexString()
    {
        _index++;
        var output = new List<byte>();
        int? high = null;
        while (_index < _bytes.Length)
        {
            var c = _bytes[_index++];
            if (c == (byte)'>') break;
            int value;
            if (c is >= 0x30 and <= 0x39) value = c - 0x30;
            else if (c is >= 0x41 and <= 0x46) value = c - 0x41 + 10;
            else if (c is >= 0x61 and <= 0x66) value = c - 0x61 + 10;
            else continue;
            if (high is { } h) { output.Add((byte)(h << 4 | value)); high = null; }
            else high = value;
        }
        if (high is { } last) output.Add((byte)(last << 4));
        return output.ToArray();
    }

    List<ContentOperand> ParseArray()
    {
        var items = new List<ContentOperand>();
        while (true)
        {
            SkipWhitespace();
            if (_index >= _bytes.Length || NextToken() is not { } token) return items;
            switch (token.Kind)
            {
                case Kind.ArrayEnd: return items;
                case Kind.Operand: items.Add(token.Operand!); break;
                case Kind.ArrayStart: items.Add(new ContentOperand.Array(ParseArray())); break;
                case Kind.DictStart: items.Add(new ContentOperand.Dict(ParseDict())); break;
                case Kind.Keyword:
                    if (token.Word == "true") items.Add(new ContentOperand.Bool(true));
                    else if (token.Word == "false") items.Add(new ContentOperand.Bool(false));
                    else if (token.Word == "null") items.Add(ContentOperand.NullValue);
                    break;
            }
        }
    }

    Dictionary<string, ContentOperand> ParseDict()
    {
        var result = new Dictionary<string, ContentOperand>();
        string? key = null;
        while (true)
        {
            SkipWhitespace();
            if (_index >= _bytes.Length || NextToken() is not { } token) return result;
            ContentOperand? value;
            switch (token.Kind)
            {
                case Kind.DictEnd: return result;
                case Kind.Operand: value = token.Operand; break;
                case Kind.ArrayStart: value = new ContentOperand.Array(ParseArray()); break;
                case Kind.DictStart: value = new ContentOperand.Dict(ParseDict()); break;
                case Kind.Keyword: value = token.Word == "true" ? new ContentOperand.Bool(true) : token.Word == "false" ? new ContentOperand.Bool(false) : ContentOperand.NullValue; break;
                default: continue;
            }
            if (key != null) { result[key] = value!; key = null; }
            else if (value is ContentOperand.Name n) key = n.Value;
        }
    }

    /// <summary>BI &lt;key value&gt;* ID &lt;data&gt; EI; leaves the index after EI.</summary>
    Dictionary<string, ContentOperand> ParseInlineImage()
    {
        var dict = new Dictionary<string, ContentOperand>();
        string? key = null;
        while (true)
        {
            SkipWhitespace();
            if (_index >= _bytes.Length || NextToken() is not { } token) return dict;
            if (token.Kind == Kind.Keyword && token.Word == "ID") break;
            ContentOperand? value;
            switch (token.Kind)
            {
                case Kind.Operand: value = token.Operand; break;
                case Kind.ArrayStart: value = new ContentOperand.Array(ParseArray()); break;
                case Kind.DictStart: value = new ContentOperand.Dict(ParseDict()); break;
                case Kind.Keyword: value = new ContentOperand.Name(token.Word!); break;
                default: continue;
            }
            if (key != null) { dict[key] = value!; key = null; }
            else if (value is ContentOperand.Name n) key = n.Value;
        }
        // One whitespace byte separates ID from the data; the data ends at whitespace + "EI" + (whitespace | end).
        if (_index < _bytes.Length) _index++;
        for (int i = _index; i + 2 < _bytes.Length; i++)
        {
            if (IsWhitespace(_bytes[i]) && _bytes[i + 1] == (byte)'E' && _bytes[i + 2] == (byte)'I'
                && (i + 3 >= _bytes.Length || IsWhitespace(_bytes[i + 3]) || IsDelimiter(_bytes[i + 3])))
            {
                _index = i + 3;
                return dict;
            }
        }
        _index = _bytes.Length;
        return dict;
    }
}
