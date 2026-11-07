using Folio.Core;
using Folio.Core.Translate;
using Folio.Core.Translate.Services;

namespace Folio.App;

/// <summary>Queues whole-document translations (one at a time), shows their progress in the list and files the
/// results under their items. The engine is built in: nothing to install. (The macOS TranslationCoordinator.)</summary>
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
    readonly Queue<(string ItemId, string FileId)> _queue = new();
    sealed class Running(string itemId)
    {
        public string ItemId = itemId;
        public TranslationJob? Job;
        public bool Cancelled;
        public void Cancel() { Cancelled = true; Job?.Cancel(); }
    }
    Running? _running;

    public SecretStore Secrets => SecretStore.Shared;

    /// <summary>A job started or ended (on the UI thread).</summary>
    public event Action? JobsChanged;
    /// <summary>A job's progress moved (item id; on the UI thread).</summary>
    public event Action<string>? ProgressChanged;

    public JobState? JobOf(string itemId) => _jobs.GetValueOrDefault(itemId);
    public IReadOnlyCollection<string> ActiveItemIds => _jobs.Keys;

    public static string LogsDirectory => Path.Combine(TranslationJob.SupportDirectory, "logs");

    /// <summary>Starts (or queues) a translation with the current settings.</summary>
    public async Task Start(string fileId)
    {
        if (!model.Snapshot.Files.TryGetValue(fileId, out var file)) return;
        if (ConfigurationProblem(model.Settings.TranslationService) is { } problem)
        {
            if (await Dialogs.Confirm(Loc.S("翻译服务还没有配置好"), problem, Loc.S("打开设置"), Loc.S("取消")))
                App.OpenSettings("translation");
            return;
        }
        Enqueue(file.ItemId, fileId);
    }

    public void Cancel(string itemId)
    {
        var remaining = _queue.Where(q => q.ItemId != itemId).ToList();
        _queue.Clear();
        foreach (var q in remaining) _queue.Enqueue(q);
        if (_running is { } running && running.ItemId == itemId)
        {
            running.Cancel();
            if (running.Job == null) Remove(itemId);
        }
        else Remove(itemId);
    }

    public void CancelAll()
    {
        _queue.Clear();
        _running?.Cancel();
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

    void Enqueue(string itemId, string fileId)
    {
        if (_jobs.ContainsKey(itemId)) return;
        _jobs[itemId] = new JobState { FileId = fileId, Stage = _running == null ? Loc.S("正在启动翻译") : Loc.S("等待翻译") };
        JobsChanged?.Invoke();
        _queue.Enqueue((itemId, fileId));
        Pump();
    }

    void Pump()
    {
        if (_running != null || _queue.Count == 0) return;
        var (itemId, fileId) = _queue.Dequeue();
        if (!model.Snapshot.Files.TryGetValue(fileId, out var file))
        {
            Remove(itemId);
            Pump();
            return;
        }
        var settings = model.Settings;
        var serviceId = settings.TranslationService;
        // Who translates, for the file names, taken now: settings may change while the engine runs.
        var profileName = settings.SelectedTranslationProfiles.GetValueOrDefault(serviceId) is { } id ? settings.TranslationProfiles.FirstOrDefault(p => p.Id == id)?.Name : null;
        var fields = settings.FieldsOf(serviceId);
        var provider = TranslationServiceCatalog.Service(serviceId) is { } svc ? TranslationNaming.Provider.Of(svc, fields, profileName) : new TranslationNaming.Provider(serviceId, null);
        var output = Path.Combine(TranslationJob.SupportDirectory, "output", Guid.NewGuid().ToString());
        var options = settings.TranslationOptions;
        _jobs[itemId] = new JobState { FileId = fileId, Stage = Loc.S("正在启动翻译") };
        ProgressChanged?.Invoke(itemId);
        var current = new Running(itemId);
        _running = current;
        var source = model.Library.FilePath(file);
        Task.Run(async () =>
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
                if (!current.Cancelled) model.RunOnUi(() => _ = Fail(itemId, fileId, e.Message, null));
            }
            // Give the last events their turn on the UI thread before the output folder goes.
            await Task.Delay(500);
            model.RunOnUi(() =>
            {
                if (current.Cancelled) Remove(itemId);
                try { Directory.Delete(output, true); } catch { }
                _running = null;
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
            case TranslationEvent.Finished finished:
            {
                var notices = job?.Notices ?? [];
                Remove(itemId);
                File(finished.Mono, finished.Dual, fileId, provider, options, notices).Fire();
                break;
            }
            case TranslationEvent.Failed failed:
                Fail(itemId, fileId, failed.Message, failed.LogPath).Fire();
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

    async Task Fail(string itemId, string fileId, string message, string? log)
    {
        Remove(itemId);
        var title = model.Snapshot.Items.TryGetValue(itemId, out var item) ? item.Title : "";
        switch (await Dialogs.Choose(Loc.S("「%@」翻译失败", title), message, Loc.S("重试"), log != null ? Loc.S("查看日志") : "", Loc.S("取消")))
        {
            case ContentDialogResult.Primary: await Start(fileId); break;
            case ContentDialogResult.Secondary when log != null: Shell.Reveal(log); break;
        }
    }
}
