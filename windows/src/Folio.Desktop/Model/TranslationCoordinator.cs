using Folio.Core;
using Folio.Core.Translate;
using Folio.Core.Translate.Services;

namespace Folio.App;

/// <summary>Queues whole-document translations, shows their progress in the list and files the results under their
/// items. The engine is built in: nothing to install. (The macOS TranslationCoordinator.)</summary>
public sealed class TranslationCoordinator(AppModel model)
{
    public sealed class JobState
    {
        public string FileId = "";
        public double? Fraction;
        public string Stage = "";
        public string? Preview;
        public List<string> Notices = [];
    }

    readonly Dictionary<string, JobState> _jobs = [];
    /// <summary>A paper waiting its turn, with the service and settings it was queued with (changing them in 设置 later
    /// does not change what a queued paper uses).</summary>
    sealed record Queued(string ItemId, string FileId, string ServiceId, Dictionary<string, string> Fields, TranslationOptions Options, string? ProfileName);
    readonly List<Queued> _queue = [];
    sealed class Running(string itemId, string serviceId)
    {
        public string ItemId = itemId;
        public string ServiceId = serviceId;
        public TranslationJob? Job;
        public bool Cancelled;
        public void Cancel() { Cancelled = true; Job?.Cancel(); }
    }
    /// <summary>Translations running now, by item.</summary>
    readonly Dictionary<string, Running> _running = [];
    /// <summary>Papers of one service at the same time (设置 ▸ 翻译 ▸ 同一服务同时翻译): what a service's rate limits and a
    /// local model's or agent's machine can take.</summary>
    int PerService => Math.Clamp(model.Settings.TranslationParallelJobs, 1, 4);
    /// <summary>Papers at the same time across all services (设置 ▸ 翻译 ▸ 同时翻译总数): what this PC can lay out and
    /// typeset at once.</summary>
    int Total => Math.Max(PerService, Math.Clamp(model.Settings.TranslationParallelTotal, 1, 8));

    int RunningCount(string serviceId) => _running.Values.Count(r => r.ServiceId == serviceId);

    public SecretStore Secrets => SecretStore.Shared;

    /// <summary>A job started or ended (on the UI thread).</summary>
    public event Action? JobsChanged;
    /// <summary>A job's progress moved (item id; on the UI thread).</summary>
    public event Action<string>? ProgressChanged;

    public JobState? JobOf(string itemId) => _jobs.GetValueOrDefault(itemId);
    public IReadOnlyCollection<string> ActiveItemIds => _jobs.Keys;

    public static string LogsDirectory => Path.Combine(TranslationJob.SupportDirectory, "logs");

    /// <summary>The settings' options for a run of <paramref name="pages"/> (empty: all). Pages are never a setting: a
    /// range saved by an earlier version stays out of every later paper.</summary>
    public static TranslationOptions OptionsFor(TranslationOptions saved, string? pages)
    {
        var options = saved.Copy();
        options.Pages = string.IsNullOrWhiteSpace(pages) ? null : pages.Trim();
        return options;
    }

    /// <summary>Starts (or queues) a translation with the current settings, and the pages typed for this run.</summary>
    public async Task Start(string fileId, string? pages = null)
    {
        if (!model.Snapshot.Files.TryGetValue(fileId, out var file)) return;
        if (ConfigurationProblem(model.Settings.TranslationService) is { } problem)
        {
            if (await Dialogs.Confirm(Loc.S("翻译服务还没有配置好"), problem, Loc.S("打开设置"), Loc.S("取消")))
                App.OpenSettings("translation");
            return;
        }
        Enqueue(file.ItemId, fileId, pages);
    }

    // MARK: New papers (设置 ▸ 翻译 ▸ 自动翻译新添加的论文)

    bool _toldNotConfigured;

    /// <summary>A paper just added (a PDF imported, saved from the browser, or downloaded for it): translated with the
    /// current settings when 自动翻译新添加的论文 is on and it has no translation yet. Waits for metadata retrieval, which
    /// may rename the file, and lets a scan be recognised first (the queue does that).</summary>
    public async void TranslateNewPaper(string itemId)
    {
        if (!model.Settings.AutoTranslateImports) return;
        // The new item reaches the snapshot a moment after it is added (a few seconds at most); then up to a minute for
        // retrieval to settle.
        for (int k = 0; k < 70; k++)
        {
            if (model.Snapshot.Items.TryGetValue(itemId, out var item))
            {
                if (item.MetadataState != MetadataState.Pending) break;
            }
            else if (k >= 10) return;
            await Task.Delay(1000);
        }
        if (!model.Settings.AutoTranslateImports || _jobs.ContainsKey(itemId) || UntranslatedPdf(itemId, model.Snapshot) is not { } file) return;
        if (ConfigurationProblem(model.Settings.TranslationService) is { } problem)
        {
            // Said once, not at every import.
            if (!_toldNotConfigured)
            {
                _toldNotConfigured = true;
                model.Toasts.Show(Loc.S("没有自动翻译新论文：%@", problem), "warning");
            }
            return;
        }
        Enqueue(file.ItemId, file.Id, null);
    }

    /// <summary>The paper's PDF to translate: an original (not a translation, not named like one) when the paper has no
    /// translation yet.</summary>
    public static FileRecord? UntranslatedPdf(string itemId, LibrarySnapshot snapshot)
    {
        var files = snapshot.FilesOf(itemId);
        if (files.Any(f => f.TranslationKind != null || f.TranslationOf != null)) return null;
        string[] marks = ["双语对照", "译文", ".dual", ".mono", "-dual", "-mono", "_dual", "_mono"];
        var originals = files.Where(f => f.IsPdf && !marks.Any(m => f.FileName.Contains(m, StringComparison.OrdinalIgnoreCase))).ToList();
        var defaultId = snapshot.Items.GetValueOrDefault(itemId)?.DefaultFileId;
        return originals.FirstOrDefault(f => f.Id == defaultId) ?? originals.FirstOrDefault();
    }

    public void Cancel(string itemId)
    {
        _queue.RemoveAll(q => q.ItemId == itemId);
        if (_running.TryGetValue(itemId, out var running))
        {
            running.Cancel();
            if (running.Job == null) Remove(itemId);
        }
        else Remove(itemId);
    }

    public void CancelAll()
    {
        _queue.Clear();
        foreach (var running in _running.Values) running.Cancel();
    }

    /// <summary>What is missing before serviceId can run, in words for the user; null when ready.</summary>
    public string? ConfigurationProblem(string serviceId)
    {
        if (TranslationServiceCatalog.Service(serviceId) is not { } service) return Loc.S("请在设置中选择翻译服务。");
        var values = model.Settings.FieldsOf(serviceId);
        foreach (var field in service.RequiredFields)
        {
            var value = field.IsSecret ? Secrets.Get(serviceId, field.Option) : values.GetValueOrDefault(field.Option);
            if (string.IsNullOrWhiteSpace(value) && field.DefaultValue == null) return Loc.S("%@ 需要填写\"%@\"。", service.DisplayName, field.Title);
        }
        if (service.Backend is TranslationBackend.Agent agent)
        {
            var pathOption = service.Fields.FirstOrDefault(f => f.Option.EndsWith("-path"))?.Option;
            if (agent.Which.Locate(pathOption != null ? values.GetValueOrDefault(pathOption) : null) == null)
                return Loc.S("在这台电脑上找不到 %@。请先安装并登录 %@，或在设置中填写它的路径。", agent.Which.Command(), service.DisplayName);
        }
        return null;
    }

    void Remove(string itemId)
    {
        if (_jobs.Remove(itemId)) JobsChanged?.Invoke();
    }

    void Enqueue(string itemId, string fileId, string? pages)
    {
        if (_jobs.ContainsKey(itemId)) return;
        var settings = model.Settings;
        var serviceId = settings.TranslationService;
        // Who translates and how, taken now: the settings may change while the paper waits or runs.
        var profileName = settings.SelectedTranslationProfiles.GetValueOrDefault(serviceId) is { } id ? settings.TranslationProfiles.FirstOrDefault(p => p.Id == id)?.Name : null;
        _queue.Add(new Queued(itemId, fileId, serviceId, settings.FieldsOf(serviceId), OptionsFor(settings.TranslationOptions, pages), profileName));
        _jobs[itemId] = new JobState { FileId = fileId, Stage = Loc.S("等待翻译") };
        JobsChanged?.Invoke();
        Pump();
    }

    /// <summary>More papers may run at once now: starts the waiting ones.</summary>
    public void ParallelChanged() => Pump();

    /// <summary>Starts waiting papers, in the order they were queued, while there is room: in all (Total) and for their
    /// service (PerService). A paper whose service is busy waits without holding up papers for other services.</summary>
    void Pump()
    {
        while (TranslationScheduler.Next(_queue.Select(q => q.ServiceId).ToList(), _running.Values.Select(r => r.ServiceId).ToList(), PerService, Total) is { } index)
        {
            var next = _queue[index];
            _queue.RemoveAt(index);
            StartNext(next);
        }
        // What the waiting ones are waiting for.
        foreach (var waiting in _queue)
        {
            if (!_jobs.TryGetValue(waiting.ItemId, out var job)) continue;
            bool busy = RunningCount(waiting.ServiceId) >= PerService;
            var name = TranslationServiceCatalog.Service(waiting.ServiceId)?.DisplayName ?? waiting.ServiceId;
            var stage = busy ? Loc.S("等待翻译（%@ 已有 %lld 篇在翻译）", name, PerService) : Loc.S("等待翻译");
            if (job.Stage != stage)
            {
                job.Stage = stage;
                ProgressChanged?.Invoke(waiting.ItemId);
            }
        }
    }

    void StartNext(Queued next)
    {
        var (itemId, fileId, pages) = (next.ItemId, next.FileId, next.Options.Pages);
        if (!model.Snapshot.Files.TryGetValue(fileId, out var file))
        {
            Remove(itemId);
            return;
        }
        var serviceId = next.ServiceId;
        var fields = next.Fields;
        var provider = TranslationServiceCatalog.Service(serviceId) is { } svc ? TranslationNaming.Provider.Of(svc, fields, next.ProfileName) : new TranslationNaming.Provider(serviceId, null);
        var output = Path.Combine(TranslationJob.SupportDirectory, "output", Guid.NewGuid().ToString());
        var options = next.Options;
        _jobs[itemId] = new JobState { FileId = fileId, Stage = Loc.S("正在启动翻译") };
        ProgressChanged?.Invoke(itemId);
        var current = new Running(itemId, serviceId);
        _running[itemId] = current;
        var source = model.Library.FilePath(file);
        _ = RecognizeThenTranslate();

        // A scan has no text to translate: its text is recognised first (OCR-01), on the interface thread where OCR lives.
        async Task RecognizeThenTranslate()
        {
            try
            {
                if (await model.Ocr.IsScanned(fileId) && !current.Cancelled)
                {
                    SetStage(Loc.S("正在识别扫描件文字"), null);
                    await model.Ocr.RecognizeAndWait(fileId, p => SetStage(Loc.S("正在识别扫描件文字"), p.Total > 0 ? (double)p.Done / p.Total : null));
                    SetStage(Loc.S("正在启动翻译"), null);
                }
                // So has a page scanned into a paper that otherwise has text.
                else if (!current.Cancelled && await model.Ocr.HasPagesWithoutText(fileId) && !current.Cancelled)
                {
                    SetStage(Loc.S("正在识别扫描页文字"), null);
                    await model.Ocr.RecognizeScannedPages(fileId, p => SetStage(Loc.S("正在识别扫描页文字"), p.Total > 0 ? (double)p.Done / p.Total : null));
                    SetStage(Loc.S("正在启动翻译"), null);
                }
            }
            catch (Exception e)
            {
                if (!current.Cancelled) _ = Fail(itemId, fileId, pages, e.Message, null);
                if (current.Cancelled) Remove(itemId);
                _running.Remove(itemId);
                Pump();
                return;
            }
            Translate();
        }

        void SetStage(string stage, double? fraction)
        {
            if (!_jobs.TryGetValue(itemId, out var job)) return;
            job.Stage = stage;
            job.Fraction = fraction;
            ProgressChanged?.Invoke(itemId);
        }

        void Translate() => Task.Run(async () =>
        {
            try
            {
                Directory.CreateDirectory(output);
                var request = new TranslationRequest
                {
                    Input = source, OutputDirectory = output, ServiceId = serviceId, FieldValues = fields,
                    Secrets = TranslationServiceCatalog.Service(serviceId) is { } service ? Secrets.Secrets(service) : [], Options = options,
                };
                if (!current.Cancelled)
                {
                    var job = new TranslationJob(request);
                    current.Job = job;
                    await job.Run(e => model.RunOnUi(() => Handle(e, itemId, fileId, provider, options)));
                }
            }
            catch (Exception e)
            {
                if (!current.Cancelled) model.RunOnUi(() => _ = Fail(itemId, fileId, pages, e.Message, null));
            }
            // Give the last events their turn on the UI thread before the output folder goes.
            await Task.Delay(500);
            model.RunOnUi(() =>
            {
                if (current.Cancelled) Remove(itemId);
                try { Directory.Delete(output, true); } catch { }
                _running.Remove(itemId);
                Pump();
            });
        }).Fire();
    }

    void Handle(TranslationEvent e, string itemId, string fileId, TranslationNaming.Provider provider, TranslationOptions options)
    {
        var job = _jobs.GetValueOrDefault(itemId);
        switch (e)
        {
            case TranslationEvent.Stage stage when job != null:
                job.Stage = stage.Text;
                ProgressChanged?.Invoke(itemId);
                break;
            case TranslationEvent.Progress progress when job != null:
                job.Fraction = progress.Value;
                if (job.Stage == Loc.S("正在启动翻译")) job.Stage = Loc.S("正在翻译");
                ProgressChanged?.Invoke(itemId);
                break;
            case TranslationEvent.Preview preview when job != null:
                job.Preview = preview.Path;
                break;
            case TranslationEvent.Notice notice when job != null:
                job.Notices.Add(notice.Text);
                break;
            case TranslationEvent.Problem problem:
            {
                // At once, with what the service said: the translation is not stuck, and the cause may be the user's to fix.
                var title = model.Snapshot.Items.TryGetValue(itemId, out var problemItem) ? problemItem.Title : "";
                model.Toasts.Show(Loc.S("「%@」：%@", title, problem.Text), "warning");
                break;
            }
            case TranslationEvent.Finished finished:
            {
                var notices = job?.Notices ?? [];
                Remove(itemId);
                File(finished.Mono, finished.Dual, fileId, provider, options, notices).Fire();
                break;
            }
            case TranslationEvent.Failed failed:
                Fail(itemId, fileId, options.Pages, failed.Message, failed.LogPath).Fire();
                break;
            case TranslationEvent.Cancelled:
                Remove(itemId);
                model.Toasts.Show(Loc.S("已取消翻译"), "close");
                break;
        }
    }

    /// <summary>Copies the results into the library next to the original, named by language, provider and model.</summary>
    async Task File(string? mono, string? dual, string fileId, TranslationNaming.Provider provider, TranslationOptions options, List<string> notices)
    {
        if (!model.Snapshot.Files.TryGetValue(fileId, out var source)) return;
        var @base = Path.GetFileNameWithoutExtension(source.FileName);
        var language = TranslationOptions.CommonLanguages.FirstOrDefault(l => l.Code == options.LangOut).Name ?? "";
        var existing = model.Snapshot.FilesOf(source.ItemId).Select(f => Path.GetFileNameWithoutExtension(f.FileName)).ToHashSet();
        string Name(TranslationNaming.Kind kind) => TranslationNaming.BaseName(@base, kind, language, provider, existing);
        var earlier = options.Duplicates == TranslationOptions.DuplicateHandling.replace
            ? model.Snapshot.Files.Values.Where(f => f.TranslationOf == fileId && f.TranslatedBy == provider.Label).Select(f => f.Id).ToList() : [];
        var added = new List<FileRecord>();
        try
        {
            var library = model.Library;
            string? monoName = mono != null ? Name(TranslationNaming.Kind.Mono) : null, dualName = dual != null ? Name(TranslationNaming.Kind.Dual) : null;
            // Hashing and copying large files: not on the UI thread.
            await Task.Run(() =>
            {
                if (mono != null) added.Add(library.AddTranslatedFile(mono, fileId, TranslationKind.Mono, monoName!, provider.Label));
                if (dual != null) added.Add(library.AddTranslatedFile(dual, fileId, TranslationKind.Dual, dualName!, provider.Label));
            });
        }
        catch (Exception e)
        {
            model.Toasts.Show(Loc.S("无法保存译文") + "：" + e.Message, "warning");
        }
        if (added.Count == 0) return;
        if (earlier.Count > 0) model.Perform(() => model.Library.TrashFiles(earlier));
        model.Importer.IndexFulltext();
        var title = model.Snapshot.Items.TryGetValue(source.ItemId, out var item) ? item.Title : @base;
        var done = string.Join(" ", new[] { Loc.S("「%@」翻译完成", title) }.Concat(notices));
        var first = added[0];
        model.Toasts.Show(done, "translate", Loc.S("打开译文"), () =>
        {
            if (model.Snapshot.Files.TryGetValue(first.Id, out var f)) model.OpenFile(f);
        });
    }

    /// <summary>Says why a translation failed; 重试 runs it again as it was (the same pages).</summary>
    async Task Fail(string itemId, string fileId, string? pages, string message, string? log)
    {
        Remove(itemId);
        var title = model.Snapshot.Items.TryGetValue(itemId, out var item) ? item.Title : "";
        switch (await Dialogs.Choose(Loc.S("「%@」翻译失败", title), message, Loc.S("重试"), log != null ? Loc.S("查看日志") : "", Loc.S("取消")))
        {
            case ContentDialogResult.Primary: await Start(fileId, pages); break;
            case ContentDialogResult.Secondary when log != null: Shell.Reveal(log); break;
        }
    }
}
