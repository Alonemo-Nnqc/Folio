using System.Text.Json;
using Folio.Core;

namespace Folio.App;

/// <summary>One open PDF: its address for the page, and the changes written to the file, one at a time and off the interface thread.</summary>
sealed class PdfSession(string path)
{
    public string Path_ => path;
    Task _writes = Task.CompletedTask;
    readonly Stack<(long Before, long After)> _undo = new();
    readonly Stack<(long Before, byte[] Tail)> _redo = new();
    DateTime _loadedStamp;
    long _loadedLength;

    public void RememberFile()
    {
        try { var info = new FileInfo(path); _loadedStamp = info.LastWriteTimeUtc; _loadedLength = info.Length; }
        catch (IOException) { }
    }

    /// <summary>The file changed underneath the reader (another app, an AI agent, a sync client).</summary>
    public bool ChangedOnDisk()
    {
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists || (info.LastWriteTimeUtc == _loadedStamp && info.Length == _loadedLength)) return false;
        }
        catch (IOException) { return false; }
        RememberFile();
        lock (_undo) { _undo.Clear(); _redo.Clear(); }
        return true;
    }

    /// <summary>Runs a change to the PDF, remembers how to undo it (changes only append, so undoing is cutting the end off).
    /// The result goes to the page; the page itself has already drawn the change.</summary>
    public Task<object?> Change(Func<string, object?> change) => Enqueue(() =>
    {
        long before = new FileInfo(path).Length;
        var message = change(path);
        long after = new FileInfo(path).Length;
        if (after != before) lock (_undo) { _undo.Push((before, after)); _redo.Clear(); }
        return message;
    });

    public Task<object?> Undo() => Enqueue(() =>
    {
        lock (_undo)
        {
            if (_undo.Count == 0) return null;
            var (before, after) = _undo.Pop();
            if (new FileInfo(path).Length != after) { _undo.Clear(); _redo.Clear(); throw new IOException(Loc.S("文件已被其他程序修改")); }
            _redo.Push((before, AnnotationWriter.TruncateTo(path, before)));
            return new { cmd = "undone" };
        }
    });

    public Task<object?> Redo() => Enqueue(() =>
    {
        lock (_undo)
        {
            if (_redo.Count == 0) return null;
            var (before, tail) = _redo.Pop();
            if (new FileInfo(path).Length != before) { _undo.Clear(); _redo.Clear(); throw new IOException(Loc.S("文件已被其他程序修改")); }
            AnnotationWriter.Append(path, tail);
            _undo.Push((before, before + tail.Length));
            return new { cmd = "redone" };
        }
    });

    Task<object?> Enqueue(Func<object?> work)
    {
        var done = new TaskCompletionSource<object?>();
        _writes = _writes.ContinueWith(_ =>
        {
            try
            {
                var message = work();
                App.Ui.TryEnqueue(() =>
                {
                    RememberFile();
                    App.Model.Importer.RefreshChangedFiles();
                    done.SetResult(message);
                });
            }
            catch (Exception e)
            {
                CrashLog.Write(e);
                App.Model.Toasts.Show(Loc.S("无法保存标注：%@", e.Message), "warning");
                // What the page shows may no longer be what the file holds.
                App.Ui.TryEnqueue(() =>
                {
                    lock (_undo) { _undo.Clear(); _redo.Clear(); }
                    RememberFile();
                    done.SetResult(new { cmd = "reloadCurrent" });
                });
            }
        }, TaskScheduler.Default);
        return done.Task;
    }
}

public static partial class Api
{
    static readonly Dictionary<string, PdfSession> Sessions = [];

    static PdfSession Session(Args a) => Sessions.TryGetValue(a.Str("session"), out var s) ? s : throw new InvalidOperationException("Reader session is gone");

    static object Resolved(IReadOnlyList<string> temps, IReadOnlyList<long> numbers) =>
        new { cmd = "resolved", map = temps.Zip(numbers, (temp, number) => new { temp, id = $"{number}R" }).ToArray() };

    static string? Author => Text.NonEmpty(M.Settings.AnnotationAuthor);

    /// <summary>pdf.js names an annotation after its object: "123R".</summary>
    static long ObjectNumber(string id)
    {
        var digits = new string(id.TakeWhile(char.IsDigit).ToArray());
        return long.TryParse(digits, out var n) ? n : throw new InvalidOperationException(Loc.S("这个批注不能修改"));
    }

    static string FileUrl(string relative) => $"https://folio.library/{string.Join('/', relative.Split('\\', '/').Select(Uri.EscapeDataString))}?v={DateTime.UtcNow.Ticks}";

    static void InstallReader()
    {
        // A paper in the library, or (preview) a translation still being written.
        Bridge.On("reader.openFile", a =>
        {
            var id = a.Str("file");
            if (!M.Snapshot.Files.TryGetValue(id, out var file)) throw new FileNotFoundException(id);
            var path = M.Library.FilePath(file);
            var session = Guid.NewGuid().ToString("N");
            var pdf = new PdfSession(path);
            pdf.RememberFile();
            Sessions[session] = pdf;
            var state = M.Library.ReadingState(id);
            return new
            {
                session, url = FileUrl(Path.GetRelativePath(M.Library.Root, path)),
                state = state == null ? null : new { page = state.PageIndex + 1, scale = state.AutoScale ? (double?)null : state.Scale, top = state.PointY, left = state.PointX },
            };
        });
        Bridge.On("reader.openPreview", a =>
        {
            var path = a.Str("path");
            var session = Guid.NewGuid().ToString("N");
            var pdf = new PdfSession(path);
            pdf.RememberFile();
            Sessions[session] = pdf;
            return new { session, url = PreviewUrl(a, path) };
        });
        Bridge.On("reader.previewUrl", a => PreviewUrl(a, a.Str("path")));
        Bridge.On("reader.url", a =>
        {
            var session = Session(a);
            return FileUrl(Path.GetRelativePath(M.Library.Root, session.Path_));
        });
        Bridge.On("reader.close", a => { Sessions.Remove(a.Str("session")); return null; });
        Bridge.On("reader.changedOnDisk", a => Session(a).ChangedOnDisk());
        Bridge.On("reader.savePosition", a =>
        {
            M.SaveReadingState(new ReadingState(a.Str("file"), a.Int("page") - 1, a.Has("left") ? a.Num("left") : 0, a.Has("top") ? a.Num("top") : 0,
                a.Has("scale") ? a.Num("scale") : 1, a.Bool("autoScale", true), M.Settings.ReaderLayout == ReaderLayout.TwoUp ? 3 : 1, DateTime.UtcNow));
            return null;
        });

        Bridge.OnAsync("reader.undo", a => Session(a).Undo());
        Bridge.OnAsync("reader.redo", a => Session(a).Redo());
        Bridge.OnAsync("reader.markup", a =>
        {
            var subtype = a.Str("subtype");
            var color = a.Str("color");
            var annotations = new List<NewAnnotation>();
            var temps = new List<string>();
            foreach (var page in a.Raw("pages").EnumerateArray())
            {
                var quads = page.GetProperty("quads").EnumerateArray().Select(q => q.EnumerateArray().Select(v => v.GetDouble()).ToArray()).ToList();
                annotations.Add(new NewAnnotation(page.GetProperty("page").GetInt32(), subtype, color, Quads: quads, Author: Author));
                temps.Add(page.GetProperty("temp").GetString()!);
            }
            return Session(a).Change(path => Resolved(temps, AnnotationWriter.Add(path, annotations)));
        });
        Bridge.OnAsync("reader.ink", a =>
        {
            var strokes = a.Raw("strokes").EnumerateArray().Select(s => s.EnumerateArray().Select(v => v.GetDouble()).ToArray()).ToList();
            int page = a.Int("page");
            var temp = a.Str("temp");
            var color = a.Str("color");
            return Session(a).Change(path => Resolved([temp], AnnotationWriter.Add(path, [new NewAnnotation(page, "Ink", color, Strokes: strokes, Author: Author)])));
        });
        Bridge.OnAsync("reader.addText", a =>
        {
            int page = a.Int("page");
            var subtype = a.Str("subtype");
            var color = a.Str("color");
            var temp = a.Str("temp");
            var text = a.Str("contents");
            var rect = a.Raw("rect").EnumerateArray().Select(v => v.GetDouble()).ToArray();
            return Session(a).Change(path => Resolved([temp], AnnotationWriter.Add(path, [new NewAnnotation(page, subtype, color, Rect: rect, Contents: text, Author: Author)])));
        });
        Bridge.OnAsync("reader.modify", a =>
        {
            int page = a.Int("page");
            long number = ObjectNumber(a.Str("id"));
            string? contents = a.OptStr("contents"), color = a.OptStr("color");
            double? dx = a.Has("dx") ? a.Num("dx") : null, dy = a.Has("dy") ? a.Num("dy") : null;
            return Session(a).Change(path =>
            {
                if (dx != null) AnnotationWriter.Modify(path, page, number, dx: dx.Value, dy: dy ?? 0);
                else if (contents != null) AnnotationWriter.Modify(path, page, number, contents: contents);
                else if (color != null) AnnotationWriter.Modify(path, page, number, color: color);
                return null;
            });
        });
        Bridge.OnAsync("reader.remove", a =>
        {
            int page = a.Int("page");
            long number = ObjectNumber(a.Str("id"));
            return Session(a).Change(path => { AnnotationWriter.Remove(path, page, number); return null; });
        });
        Bridge.On("reader.labels", _ => new Dictionary<string, string>
        {
            ["page"] = Loc.S("第 %lld 页", 0).Replace("0", "%d"),
            ["thumbnails"] = Loc.S("缩略图"), ["outline"] = Loc.S("目录"), ["annotations"] = Loc.S("批注"), ["hits"] = Loc.S("查找结果"),
            ["noAnnotations"] = Loc.S("没有批注"), ["noAnnotationsDetail"] = Loc.S("选中文字后用工具栏添加高亮"),
            ["noOutline"] = Loc.S("没有目录"), ["noOutlineDetail"] = Loc.S("这份 PDF 没有内置目录"),
            ["noMatches"] = Loc.S("未找到"), ["searchHint"] = Loc.S("在工具栏搜索框中输入，结果会列在这里"),
            ["openFailed"] = Loc.S("无法打开这个 PDF"), ["encrypted"] = Loc.S("这个 PDF 需要密码"),
            ["Highlight"] = Loc.S("高亮"), ["Underline"] = Loc.S("下划线"), ["StrikeOut"] = Loc.S("删除线"),
            ["Text"] = Loc.S("便签"), ["FreeText"] = Loc.S("文本框"), ["Ink"] = Loc.S("手绘"),
        });
    }

    static string PreviewUrl(Args a, string path)
    {
        var host = (a.Window ?? App.Main).MapPreview(Path.GetDirectoryName(path)!);
        return $"https://{host}/{Uri.EscapeDataString(Path.GetFileName(path))}?v={DateTime.UtcNow.Ticks}";
    }
}
