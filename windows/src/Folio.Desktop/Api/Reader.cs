using System.Text.Json;
using Folio.Core;

namespace Folio.App;

/// <summary>One open PDF: its address for the page, and the changes written to the file, one at a time and off the interface thread.</summary>
sealed class PdfSession(string path)
{
    public string Path_ => path;
    Task _writes = Task.CompletedTask;
    /// <summary>Annotation changes append (undone by cutting the end off: Before/After); a text edit rewrites the file
    /// (undone by writing the whole file back: Whole holds the other version).</summary>
    readonly Stack<(long Before, long After, byte[]? Whole, int? Page)> _undo = new();
    readonly Stack<(long Before, byte[] Tail, byte[]? Whole, int? Page)> _redo = new();
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
    /// The result goes to the page; the page itself has already drawn the change. A change of a page's content (编辑 PDF
    /// 文字) names the page: undoing or redoing it has that page drawn again.</summary>
    public Task<object?> Change(Func<string, object?> change, int? page = null) => Enqueue(() =>
    {
        long before = new FileInfo(path).Length;
        var message = change(path);
        long after = new FileInfo(path).Length;
        if (after != before) lock (_undo) { _undo.Push((before, after, null, page)); _redo.Clear(); }
        return message;
    });

    /// <summary>Replaces the whole file with what make returns (编辑 PDF 文字, EDIT-01): one undo step that puts the
    /// earlier version back. The page reloads.</summary>
    public Task<object?> Rewrite(Func<string, byte[]> make) => Enqueue(() =>
    {
        var old = File.ReadAllBytes(path);
        var data = make(path);
        WriteWhole(data);
        lock (_undo) { _undo.Push((0, data.Length, old, null)); _redo.Clear(); }
        return new { cmd = "reloadCurrent" };
    });

    void WriteWhole(byte[] data)
    {
        var temp = path + ".folio-editing";
        File.WriteAllBytes(temp, data);
        File.Move(temp, path, true);
    }

    public Task<object?> Undo() => Enqueue(() =>
    {
        lock (_undo)
        {
            if (_undo.Count == 0) return null;
            var (before, after, whole, page) = _undo.Pop();
            if (new FileInfo(path).Length != after) { _undo.Clear(); _redo.Clear(); throw new IOException(Loc.S("文件已被其他程序修改")); }
            if (whole != null)
            {
                var current = File.ReadAllBytes(path);
                WriteWhole(whole);
                _redo.Push((whole.Length, [], current, null));
                return new { cmd = "reloadCurrent" };
            }
            _redo.Push((before, AnnotationWriter.TruncateTo(path, before), null, page));
            return page is { } changed ? new { cmd = "pageChanged", page = changed } : (object)new { cmd = "undone" };
        }
    });

    public Task<object?> Redo() => Enqueue(() =>
    {
        lock (_undo)
        {
            if (_redo.Count == 0) return null;
            var (before, tail, whole, page) = _redo.Pop();
            if (new FileInfo(path).Length != before) { _undo.Clear(); _redo.Clear(); throw new IOException(Loc.S("文件已被其他程序修改")); }
            if (whole != null)
            {
                var current = File.ReadAllBytes(path);
                WriteWhole(whole);
                _undo.Push((0, whole.Length, current, null));
                return new { cmd = "reloadCurrent" };
            }
            AnnotationWriter.Append(path, tail);
            _undo.Push((before, before + tail.Length, null, page));
            return page is { } changed ? new { cmd = "pageChanged", page = changed } : (object)new { cmd = "redone" };
        }
    });

    /// <summary>Work that reads the file, after the changes before it are written.</summary>
    public Task<object?> Read(Func<string, object?> work) => Enqueue(() => work(path), wrote: false);

    Task<object?> Enqueue(Func<object?> work, bool wrote = true)
    {
        var done = new TaskCompletionSource<object?>();
        _writes = _writes.ContinueWith(_ =>
        {
            try
            {
                var message = work();
                App.Ui.TryEnqueue(() =>
                {
                    if (wrote)
                    {
                        RememberFile();
                        App.Model.Importer.RefreshChangedFiles();
                    }
                    done.SetResult(message);
                });
            }
            catch (Exception e)
            {
                CrashLog.Write(e);
                App.Model.Toasts.Show(Loc.S("无法保存修改：%@", e.Message), "warning");
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

    /// <summary>A paragraph open for editing in place, with its own undo while it is edited.</summary>
    sealed class OpenParagraph(Folio.Core.Translate.Edit.ParagraphEditing editing, long fileLength)
    {
        public Folio.Core.Translate.Edit.ParagraphEditing Editing { get; } = editing;
        public long FileLength { get; } = fileLength;
        public List<Folio.Core.Translate.Edit.PdfParagraph.State> Undo { get; } = [];
        public List<Folio.Core.Translate.Edit.PdfParagraph.State> Redo { get; } = [];
        public (int Kind, DateTime At)? Last { get; set; }
    }

    static readonly Dictionary<string, OpenParagraph> Paragraphs = [];

    static (string Id, OpenParagraph Open) Paragraph(Args a)
    {
        var id = a.Str("id");
        lock (Paragraphs) return Paragraphs.TryGetValue(id, out var open) ? (id, open) : throw new InvalidOperationException("Paragraph is gone");
    }

    /// <summary>What the page's editor needs after each change: the text of each atom (the caret steps over them), where
    /// the caret cannot stand, the lines with their caret positions (page space), and the lines set again as a one-page
    /// PDF with where it paints over the page.</summary>
    static object ParagraphState(string id, OpenParagraph open)
    {
        var editing = open.Editing;
        var paragraph = editing.Paragraph;
        var preview = editing.Preview();
        var bounds = paragraph.Bounds;
        return new
        {
            id, page = editing.PageNumber, count = paragraph.Count, texts = paragraph.Texts(),
            noStops = Enumerable.Range(0, paragraph.Count + 1).Where(i => !paragraph.IsStop(i)).ToList(),
            lines = paragraph.ShownLines().Select(l => new { b = l.Baseline, t = l.Top, d = l.Bottom, s = l.Stops.Select(st => new[] { st.Index, Math.Round(st.X, 3) }).ToList() }).ToList(),
            bounds = new[] { bounds.MinX, bounds.MinY, bounds.MaxX, bounds.MaxY },
            overflows = paragraph.Overflows, modified = paragraph.IsModified, canUndo = open.Undo.Count > 0, canRedo = open.Redo.Count > 0,
            preview = preview is { } p ? Convert.ToBase64String(p.Pdf) : null,
            paint = preview is { } q ? q.Paint.Select(r => new[] { r.MinX, r.MinY, r.MaxX, r.MaxY }).ToList() : null,
        };
    }

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
        // The eraser (READER-30): the page already shows the result; the same tracks are cut out of the file, one undo step.
        Bridge.OnAsync("reader.erase", a =>
        {
            int page = a.Int("page");
            var numbers = a.Strs("ids").Select(ObjectNumber).Distinct().ToList();
            var paths = a.Raw("paths").EnumerateArray().Select(p => p.EnumerateArray().Select(v => v.GetDouble()).ToArray()).ToList();
            double radius = a.Num("radius");
            return Session(a).Change(path => { AnnotationWriter.EraseInk(path, numbers.Select(n => new InkErasure(page, n, paths, radius)).ToList()); return null; });
        });
        // 编辑 PDF 文字 (EDIT-01): the blocks of a page, and one replaced.
        Bridge.OnAsync("reader.textBlocks", async a =>
        {
            var session = Session(a);
            int page = a.Int("page");
            return (object?)await Task.Run(() => Folio.Core.Translate.Edit.PdfTextEditor.Blocks(session.Path_, page).Select(b => new
            {
                index = b.Index, rect = new[] { b.Left, b.Bottom, b.Right, b.Top }, text = b.Text, fontSize = b.FontSize, lineHeight = b.LineHeight,
                color = b.Color, bold = b.IsBold, italic = b.IsItalic, serif = b.IsSerif, alignment = b.Alignment, editable = b.IsEditable, reason = b.Reason,
            }).ToList());
        });
        // 编辑 PDF 文字 in place (EDIT-01): a paragraph opened, edited a change at a time (each answered with the lines as
        // they are now and a preview of them), and written into the file as an update of its page only.
        Bridge.OnAsync("reader.paragraphOpen", a =>
        {
            var session = Session(a);
            int page = a.Int("page"), index = a.Int("block");
            return session.Read(path =>
            {
                var data = File.ReadAllBytes(path);
                var editing = Folio.Core.Translate.Edit.ParagraphEditing.Open(path, data, page, index);
                if (editing == null) return new { refused = Loc.S("这段文字的排版无法原样修改") };
                var id = Guid.NewGuid().ToString("N");
                var open = new OpenParagraph(editing, data.Length);
                lock (Paragraphs) Paragraphs[id] = open;
                lock (open) return ParagraphState(id, open);
            });
        });
        Bridge.OnAsync("reader.paragraphEdit", a =>
        {
            var (id, open) = Paragraph(a);
            int start = a.Int("start"), end = a.Int("end"), kind = a.Int("kind");
            var text = a.Str("text");
            bool record = a.Bool("record", true);
            return Task.Run<object?>(() =>
            {
                lock (open)
                {
                    var paragraph = open.Editing.Paragraph;
                    // One undo step for a run of typing (or deleting); a new one after a pause or another kind of edit.
                    if (record && !(open.Last is { } last && last.Kind == kind && (DateTime.UtcNow - last.At).TotalSeconds < 1.5))
                    {
                        open.Undo.Add(paragraph.Snapshot);
                        open.Redo.Clear();
                    }
                    open.Last = record ? (kind, DateTime.UtcNow) : open.Last;
                    paragraph.Replace(start, end, text);
                    return ParagraphState(id, open);
                }
            });
        });
        Bridge.OnAsync("reader.paragraphUndo", a =>
        {
            var (id, open) = Paragraph(a);
            bool redo = a.Bool("redo", false);
            return Task.Run<object?>(() =>
            {
                lock (open)
                {
                    var from = redo ? open.Redo : open.Undo;
                    var to = redo ? open.Undo : open.Redo;
                    if (from.Count == 0) return null;
                    var paragraph = open.Editing.Paragraph;
                    to.Add(paragraph.Snapshot);
                    paragraph.Snapshot = from[^1];
                    from.RemoveAt(from.Count - 1);
                    open.Last = null;
                    return ParagraphState(id, open);
                }
            });
        });
        Bridge.OnAsync("reader.paragraphCommit", a =>
        {
            var session = Session(a);
            var (id, open) = Paragraph(a);
            lock (Paragraphs) Paragraphs.Remove(id);
            var editing = open.Editing;
            if (!editing.Paragraph.IsModified) { editing.Dispose(); return Task.FromResult<object?>(null); }
            if (editing.Paragraph.Overflows) App.Model.Toasts.Show(Loc.S("这段文字比原来长，已超出原有的位置"), "warning");
            int page = editing.PageNumber;
            return session.Change(path =>
            {
                try
                {
                    // Written over what it was read from: the file must not have changed under it.
                    if (new FileInfo(path).Length != open.FileLength) throw new IOException(Loc.S("文件已被其他程序修改"));
                    lock (open) editing.Apply();
                }
                finally { editing.Dispose(); }
                return new { cmd = "pageChanged", page };
            }, page);
        });
        Bridge.On("reader.paragraphClose", a =>
        {
            var id = a.Str("id");
            OpenParagraph? open;
            lock (Paragraphs) { if (Paragraphs.Remove(id, out open)) { } }
            open?.Editing.Dispose();
            return null;
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
