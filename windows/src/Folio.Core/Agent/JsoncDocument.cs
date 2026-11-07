using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Folio.Core.Agent;

// Port of macos/.../FolioAgent/JSONCEditor.swift.

/// <summary>A JSON value with ordered keys, for the entries Folio writes into other apps' configuration.</summary>
public abstract record OrderedJson
{
    public sealed record Str(string Value) : OrderedJson;
    public sealed record Bool(bool Value) : OrderedJson;
    public sealed record Arr(List<OrderedJson> Items) : OrderedJson;
    public sealed record Obj(List<(string Key, OrderedJson Value)> Members) : OrderedJson;

    /// <summary>Pretty-printed with unit per level; continuation lines start with indent.</summary>
    public string Render(string indent, string unit) => this switch
    {
        Str s => Quote(s.Value),
        Bool b => b.Value ? "true" : "false",
        Arr a => "[" + string.Join(", ", a.Items.Select(i => i.Render(indent, unit))) + "]",
        Obj { Members.Count: 0 } => "{}",
        Obj o => "{\n" + string.Join(",\n", o.Members.Select(m => $"{indent + unit}{Quote(m.Key)}: {m.Value.Render(indent + unit, unit)}")) + $"\n{indent}}}",
        _ => "null",
    };

    public static string Quote(string text)
    {
        var sb = new StringBuilder("\"");
        foreach (var c in text)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20) sb.Append($"\\u{(int)c:X4}"); else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }
}

public sealed class JsoncException(string message) : Exception(message);

/// <summary>Edits JSON / JSON-with-comments files the way VS Code's jsonc-parser does: Folio's one member is replaced,
/// inserted or removed, and every other byte — key order, indentation, comments, trailing commas — stays as it was.</summary>
public sealed class JsoncDocument(string text)
{
    public string Text { get; private set; } = text;

    /// <summary>The document as JSON (comments and trailing commas ignored).</summary>
    public JsonObject Object()
    {
        var body = Text.TrimStart('﻿');
        if (body.Trim().Length == 0) return [];
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(StrippingComments(body), documentOptions: new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
        }
        catch { throw new JsoncException("not valid JSON"); }
        return root as JsonObject ?? throw new JsoncException("the top level is not an object");
    }

    /// <summary>JSON text without // and /* */ comments and without trailing commas.</summary>
    public static string StrippingComments(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        var output = new List<byte>(bytes.Length);
        int i = 0;
        int? pendingComma = null;
        while (i < bytes.Length)
        {
            byte b = bytes[i];
            if (b == (byte)'"')
            {
                pendingComma = null;
                int end = Scanner.StringEnd(bytes, i);
                output.AddRange(bytes[i..end]);
                i = end;
                continue;
            }
            if (b == (byte)'/' && i + 1 < bytes.Length && bytes[i + 1] == (byte)'/')
            {
                while (i < bytes.Length && bytes[i] != (byte)'\n') i++;
                continue;
            }
            if (b == (byte)'/' && i + 1 < bytes.Length && bytes[i + 1] == (byte)'*')
            {
                i += 2;
                while (i + 1 < bytes.Length && !(bytes[i] == (byte)'*' && bytes[i + 1] == (byte)'/')) i++;
                i = Math.Min(i + 2, bytes.Length);
                output.Add((byte)' ');
                continue;
            }
            if ((b == (byte)'}' || b == (byte)']') && pendingComma is { } comma) output[comma] = (byte)' ';
            if (b == (byte)',') pendingComma = output.Count;
            else if (!Scanner.IsSpace(b)) pendingComma = null;
            output.Add(b);
            i++;
        }
        return Encoding.UTF8.GetString(output.ToArray());
    }

    /// <summary>Sets root[container][name] to value, or removes it when value is null.</summary>
    public void SetMember(string name, string container, OrderedJson? value)
    {
        if (Text.Trim().Length == 0)
        {
            if (value == null) return;
            Text = new OrderedJson.Obj([(container, new OrderedJson.Obj([(name, value)]))]).Render("", "  ") + "\n";
            return;
        }
        Object();
        var bytes = Encoding.UTF8.GetBytes(Text).ToList();
        var scanner = new Scanner(bytes.ToArray());
        var root = scanner.ParseRoot() ?? throw new JsoncException("the top level is not an object");
        var unit = IndentUnit(bytes, root);
        var member = root.Members.FirstOrDefault(m => m.Key == container);
        if (member != null)
        {
            if (member.Object is not { } inner)
            {
                if (value == null) return;
                var indent = LineIndent(bytes, member.KeyStart);
                Replace(bytes, member.ValueStart, member.ValueEnd, new OrderedJson.Obj([(name, value)]).Render(indent, unit));
            }
            else
            {
                var containerIndent = LineIndent(bytes, member.KeyStart);
                var existing = inner.Members.FirstOrDefault(m => m.Key == name);
                if (existing != null)
                {
                    if (value != null) Replace(bytes, existing.ValueStart, existing.ValueEnd, value.Render(LineIndent(bytes, existing.KeyStart), unit));
                    else Remove(existing, inner, bytes);
                }
                else if (value != null) Insert(name, value, inner, containerIndent + unit, containerIndent, unit, bytes);
            }
        }
        else if (value != null)
            Insert(container, new OrderedJson.Obj([(name, value)]), root, unit, "", unit, bytes);
        Text = Encoding.UTF8.GetString(bytes.ToArray());
    }

    static void Replace(List<byte> bytes, int start, int end, string text)
    {
        bytes.RemoveRange(start, end - start);
        bytes.InsertRange(start, Encoding.UTF8.GetBytes(text));
    }

    static void Insert(string name, OrderedJson value, Scanner.ObjectInfo obj, string indent, string closingIndent, string unit, List<byte> bytes)
    {
        var member = $"{OrderedJson.Quote(name)}: {value.Render(indent, unit)}";
        if (obj.Members.Count > 0)
        {
            bytes.InsertRange(obj.Members[^1].ValueEnd, Encoding.UTF8.GetBytes($",\n{indent}{member}"));
        }
        else
        {
            var inside = Encoding.UTF8.GetString(bytes.GetRange(obj.Open + 1, obj.Close - obj.Open - 1).ToArray());
            var replacement = inside.Trim().Length == 0 ? $"\n{indent}{member}\n{closingIndent}" : inside.Trim(' ', '\t') + $"\n{indent}{member}\n{closingIndent}";
            Replace(bytes, obj.Open + 1, obj.Close, replacement);
        }
    }

    static void Remove(Scanner.Member member, Scanner.ObjectInfo obj, List<byte> bytes)
    {
        int index = obj.Members.FindIndex(m => m.KeyStart == member.KeyStart);
        int start = member.KeyStart, end = member.ValueEnd;
        if (index == obj.Members.Count - 1 && index > 0 && obj.Members[index - 1].CommaAfter is { } previousComma) start = previousComma;
        else if (member.CommaAfter is { } comma)
        {
            end = comma + 1;
            start = LineStartIfBlank(bytes, start);
            end = LineEndIfBlank(bytes, end);
        }
        else
        {
            start = LineStartIfBlank(bytes, start);
            end = LineEndIfBlank(bytes, end);
        }
        bytes.RemoveRange(start, end - start);
    }

    static int LineStartIfBlank(List<byte> bytes, int index)
    {
        int i = index;
        while (i > 0 && (bytes[i - 1] == (byte)' ' || bytes[i - 1] == (byte)'\t')) i--;
        return i > 0 && bytes[i - 1] != (byte)'\n' ? index : i;
    }

    static int LineEndIfBlank(List<byte> bytes, int index)
    {
        int i = index;
        while (i < bytes.Count && (bytes[i] == (byte)' ' || bytes[i] == (byte)'\t')) i++;
        if (i < bytes.Count && bytes[i] == (byte)'\n') return i + 1;
        if (i + 1 < bytes.Count && bytes[i] == (byte)'\r' && bytes[i + 1] == (byte)'\n') return i + 2;
        return index;
    }

    static string LineIndent(List<byte> bytes, int index)
    {
        int start = index;
        while (start > 0 && bytes[start - 1] != (byte)'\n') start--;
        int end = start;
        while (end < bytes.Count && (bytes[end] == (byte)' ' || bytes[end] == (byte)'\t')) end++;
        return Encoding.UTF8.GetString(bytes.GetRange(start, end - start).ToArray());
    }

    static string IndentUnit(List<byte> bytes, Scanner.ObjectInfo root)
    {
        if (root.Members.Count == 0) return "  ";
        var indent = LineIndent(bytes, root.Members[0].KeyStart);
        return indent.Length == 0 ? "  " : indent;
    }

    /// <summary>Recursive-descent scanner over UTF-8 bytes that records where objects and members are.</summary>
    sealed class Scanner(byte[] bytes)
    {
        public sealed record Member(string Key, int KeyStart, int ValueStart, int ValueEnd, int? CommaAfter, ObjectInfo? Object);
        public sealed record ObjectInfo(int Open, int Close, List<Member> Members);

        int _position;

        public static bool IsSpace(byte b) => b is 0x20 or 0x09 or 0x0A or 0x0D;

        public static int StringEnd(byte[] bytes, int start)
        {
            int i = start + 1;
            while (i < bytes.Length)
            {
                if (bytes[i] == (byte)'\\') { i += 2; continue; }
                if (bytes[i] == (byte)'"') return i + 1;
                i++;
            }
            return bytes.Length;
        }

        void SkipTrivia()
        {
            while (_position < bytes.Length)
            {
                byte b = bytes[_position];
                if (IsSpace(b)) { _position++; continue; }
                if (b == (byte)'/' && _position + 1 < bytes.Length)
                {
                    if (bytes[_position + 1] == (byte)'/')
                    {
                        while (_position < bytes.Length && bytes[_position] != (byte)'\n') _position++;
                        continue;
                    }
                    if (bytes[_position + 1] == (byte)'*')
                    {
                        _position += 2;
                        while (_position + 1 < bytes.Length && !(bytes[_position] == (byte)'*' && bytes[_position + 1] == (byte)'/')) _position++;
                        _position = Math.Min(_position + 2, bytes.Length);
                        continue;
                    }
                }
                return;
            }
        }

        public ObjectInfo? ParseRoot()
        {
            if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) _position = 3;
            SkipTrivia();
            if (_position >= bytes.Length || bytes[_position] != (byte)'{') return null;
            return ParseObject();
        }

        ObjectInfo? ParseValue()
        {
            SkipTrivia();
            if (_position >= bytes.Length) throw new JsoncException("unexpected end");
            switch (bytes[_position])
            {
                case (byte)'{': return ParseObject();
                case (byte)'[':
                    _position++;
                    while (true)
                    {
                        SkipTrivia();
                        if (_position >= bytes.Length) throw new JsoncException("unterminated array");
                        if (bytes[_position] == (byte)']') { _position++; return null; }
                        ParseValue();
                        SkipTrivia();
                        if (_position < bytes.Length && bytes[_position] == (byte)',') _position++;
                    }
                case (byte)'"':
                    _position = StringEnd(bytes, _position);
                    return null;
                default:
                    while (_position < bytes.Length && !IsSpace(bytes[_position]) && bytes[_position] is not ((byte)',' or (byte)'}' or (byte)']' or (byte)'/')) _position++;
                    return null;
            }
        }

        ObjectInfo ParseObject()
        {
            int open = _position++;
            var members = new List<Member>();
            while (true)
            {
                SkipTrivia();
                if (_position >= bytes.Length) throw new JsoncException("unterminated object");
                if (bytes[_position] == (byte)'}') return new ObjectInfo(open, _position++, members);
                if (bytes[_position] != (byte)'"') throw new JsoncException("expected a key");
                int keyStart = _position;
                _position = StringEnd(bytes, _position);
                string key;
                try { key = JsonSerializer.Deserialize<string>(bytes.AsSpan(keyStart, _position - keyStart)) ?? ""; } catch { key = ""; }
                SkipTrivia();
                if (_position >= bytes.Length || bytes[_position] != (byte)':') throw new JsoncException("expected ':'");
                _position++;
                SkipTrivia();
                int valueStart = _position;
                var obj = ParseValue();
                int valueEnd = _position;
                SkipTrivia();
                int? comma = null;
                if (_position < bytes.Length && bytes[_position] == (byte)',') comma = _position++;
                members.Add(new Member(key, keyStart, valueStart, valueEnd, comma, obj));
            }
        }
    }
}
