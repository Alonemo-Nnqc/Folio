using System.Text.RegularExpressions;

namespace Folio.Core.Agent;

/// <summary>
/// Port of YAMLServers.swift: adds and removes one server in a YAML file's top-level map (Hermes' mcp_servers, goose's
/// extensions), line by line, so everything else in the file stays exactly as it was.
/// </summary>
public static class YamlServers
{
    public sealed class Unsupported(string key) : Exception($"{key} is not a block mapping");

    static int Indent(string line) => line.TakeWhile(c => c == ' ').Count();
    static bool IsContent(string line) { var t = line.Trim(); return t.Length > 0 && !t.StartsWith('#'); }
    static List<string> Split(string text) => [.. text.Replace("\r\n", "\n").Split('\n')];

    static (int Line, int Start, int End)? Block(List<string> lines, string key)
    {
        int line = lines.FindIndex(l => l.StartsWith(key + ":", StringComparison.Ordinal));
        if (line < 0) return null;
        int end = lines.FindIndex(line + 1, l => IsContent(l) && Indent(l) == 0);
        return (line, line + 1, end < 0 ? lines.Count : end);
    }

    static (int Start, int End, int Indent)? Entry(List<string> lines, int from, int to, string name)
    {
        for (int start = from; start < to; start++)
        {
            if (!IsContent(lines[start]) || lines[start].Trim() != name + ":") continue;
            int level = Indent(lines[start]), end = start + 1;
            while (end < to && !(IsContent(lines[end]) && Indent(lines[end]) <= level)) end++;
            // Comments and blank lines after it belong to what follows.
            while (end > start + 1 && !IsContent(lines[end - 1])) end--;
            return (start, end, level);
        }
        return null;
    }

    /// <summary>The value of field in name's entry.</summary>
    public static string? Value(string field, string text, string key, string name)
    {
        var lines = Split(text);
        if (Block(lines, key) is not { } block || Entry(lines, block.Start, block.End, name) is not { } entry) return null;
        foreach (var line in lines.Skip(entry.Start + 1).Take(entry.End - entry.Start - 1))
        {
            var trimmed = line.Trim();
            if (!trimmed.StartsWith(field + ":", StringComparison.Ordinal)) continue;
            var raw = trimmed[(field.Length + 1)..].Trim();
            if (raw.StartsWith('"'))
            {
                var m = Regex.Match(raw, @"^""((?:[^""\\]|\\.)*)""");
                if (m.Success) return m.Groups[1].Value.Replace("\\\"", "\"").Replace("\\\\", "\\");
            }
            if (raw.StartsWith('\'')) return new string(raw.Skip(1).TakeWhile(c => c != '\'').ToArray());
            return raw.Split(" #")[0].Trim();
        }
        return "";
    }

    /// <summary>A double-quoted scalar.</summary>
    public static string Quoted(string value) => "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    /// <summary>text with name set to fields (lines relative to the entry), or removed when fields is null.</summary>
    public static string Edited(string text, string key, string name, string[]? fields)
    {
        var lines = Split(text);
        if (Block(lines, key) is not { } found)
        {
            if (fields == null) return text;
            while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
            if (lines.Count > 0) lines.Add("");
            return string.Join("\n", lines.Concat(new[] { $"{key}:", $"  {name}:" }).Concat(fields.Select(f => "    " + f)).Append(""));
        }
        var inline = lines[found.Line][(key.Length + 1)..].Split(" #")[0].Trim();
        if (inline is not ("" or "{}" or "null" or "~")) throw new Unsupported(key);

        int end = found.End;
        int level = Enumerable.Range(found.Start, end - found.Start).Where(i => IsContent(lines[i])).Select(i => Indent(lines[i])).DefaultIfEmpty(2).First();
        if (Entry(lines, found.Start, end, name) is { } old)
        {
            level = old.Indent;
            lines.RemoveRange(old.Start, old.End - old.Start);
            end -= old.End - old.Start;
        }
        if (fields != null)
        {
            var pad = new string(' ', level);
            lines.InsertRange(found.Line + 1, new[] { $"{pad}{name}:" }.Concat(fields.Select(f => pad + "  " + f)));
            lines[found.Line] = $"{key}:";
        }
        else if (!Enumerable.Range(found.Start, end - found.Start).Any(i => IsContent(lines[i])))
        {
            lines[found.Line] = $"{key}: {{}}";
        }
        return string.Join("\n", lines);
    }
}
