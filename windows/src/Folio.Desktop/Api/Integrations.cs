using System.IO.Compression;
using Folio.Core;
using Folio.Core.Agent;
using Folio.Core.Connector;
using Folio.Core.Translate.Services;
using Folio.Core.Zotero;

namespace Folio.App;

public static partial class Api
{
    static object ConnectorState() => new
    {
        state = M.Connector.State.ToString().ToLowerInvariant(),
        message = M.Connector.State switch
        {
            ConnectorServer.ServerState.Running => Loc.S("正在运行（127.0.0.1:%@）", ConnectorProtocol.Port.ToString()),
            ConnectorServer.ServerState.Failed => M.Connector.FailureReason ?? "",
            _ => Loc.S("已停止"),
        },
    };

    static object BrowserRows() => BrowserExtensions.Detect().Select(b =>
    {
        var (installed, enabled, version) = BrowserExtensions.InstallState(b);
        return new { id = b.Id, name = b.Name, installed, status = installed ? (enabled ? Loc.S("已安装 %@", version ?? "") : Loc.S("已安装，但已停用")) : Loc.S("未安装") };
    }).ToList();

    static object AgentDto(AgentStatus s)
    {
        var d = s.Descriptor;
        var integrator = AiIntegration.Integrator;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var details = new List<string>();
        if (s.McpInstalled && s.McpConfigPath is { } config)
            details.Add(s.McpNeedsUpdate ? Loc.S("MCP：%@（指向的 folio-cli 已不存在）", config) : Loc.S("MCP：%@", config));
        if (s.SkillFolder is { } skill)
            details.Add(skill == AgentIntegrator.SharedSkillsFolder ? Loc.S("技能：%@（共享）", integrator.Display(skill)) : Loc.S("技能：%@", integrator.Display(skill)));
        string? inline = null;
        if (AiIntegration.Hints.TryGetValue(d.Id, out var hint))
        {
            if (!AiIntegration.ShowsInline(d.Id)) details.Add(Loc.S(hint));
            else if (s.McpInstalled || s.SkillInstalled) inline = Loc.S(hint);
        }
        return new
        {
            id = d.Id, name = d.Name, detected = s.IsDetected, version = s.Version,
            location = s.Location is { } l ? (l.StartsWith(home, StringComparison.OrdinalIgnoreCase) ? "~" + l[home.Length..] : l) : null,
            mcp = s.McpInstalled, skill = s.SkillInstalled, mcpAvailable = d.Mcp != null, skillAvailable = d.SupportsSkills, skillNote = d.SkillNote ?? Loc.S("不支持技能"),
            configPath = s.McpConfigPath, details = string.Join("\n", details), inline,
        };
    }

    static List<AgentStatus>? _agentStatuses;

    static void InstallIntegrations()
    {
        // Browser.
        Bridge.On("browser.state", _ => new { connector = ConnectorState(), browsers = BrowserRows() });
        Bridge.On("browser.install", a =>
        {
            var browser = BrowserExtensions.Detect().FirstOrDefault(b => b.Id == a.Str("id"));
            if (browser == null) return null;
            try
            {
                var folder = BrowserExtensions.PrepareCopy(browser.Family);
                Shell.CopyText(folder);
                BrowserExtensions.OpenExtensionsPage(browser);
                Shell.Open(folder);
                M.Toasts.Show(Loc.S("插件文件夹的路径已复制，在扩展页面中选择“加载已解压的扩展程序”"), "copy");
            }
            catch (Exception e) { M.Toasts.Show(e.Message, "warning"); }
            return null;
        });

        // AI.
        Bridge.On("ai.info", _ => new { cliPath = AiIntegration.CliPath, cliExists = File.Exists(AiIntegration.CliPath), catalog = Loc.JoinList(AgentIntegrator.Catalog.Select(d => d.Name)) });
        Bridge.OnAsync("ai.detect", async _ =>
        {
            var result = await Task.Run(() =>
            {
                ShellEnvironment.Reset();
                return AiIntegration.Integrator.Detect();
            });
            _agentStatuses = result;
            return (object?)result.Where(x => x.IsDetected).Select(AgentDto).ToList();
        });
        Bridge.OnAsync("ai.setMcp", async a =>
        {
            var d = AgentIntegrator.Catalog.First(x => x.Id == a.Str("id"));
            bool on = a.Bool("on");
            await Task.Run(() => AiIntegration.Integrator.SetMcp(on, d));
            M.Toasts.Show((on ? Loc.S("已为 %@ 添加 Folio MCP", d.Name) : Loc.S("已从 %@ 移除 Folio MCP", d.Name)) + Loc.S("，重启该智能体或开始新会话后生效"), "checkmark");
        });
        Bridge.OnAsync("ai.setSkill", async a =>
        {
            var d = AgentIntegrator.Catalog.First(x => x.Id == a.Str("id"));
            bool on = a.Bool("on");
            await Task.Run(() => AiIntegration.Integrator.SetSkill(on, d));
            M.Toasts.Show((on ? Loc.S("已为 %@ 添加 Folio 技能", d.Name) : Loc.S("已从 %@ 移除 Folio 技能", d.Name)) + Loc.S("，重启该智能体或开始新会话后生效"), "checkmark");
        });
        Bridge.On("ai.losingSkill", a =>
        {
            var d = AgentIntegrator.Catalog.First(x => x.Id == a.Str("id"));
            var integrator = AiIntegration.Integrator;
            var detected = (_agentStatuses ?? []).Where(x => x.IsDetected).Select(x => x.Id).ToHashSet();
            var losing = integrator.AgentsLosingSkill(d).Where(x => detected.Contains(x.Id)).ToList();
            if (losing.Count == 0) return null;
            var folder = (_agentStatuses ?? []).FirstOrDefault(x => x.Id == d.Id)?.SkillFolder ?? "";
            return new
            {
                title = Loc.S("同时从 %@ 移除 Folio 技能？", Loc.JoinList(losing.Select(x => x.Name))),
                message = Loc.S("%@ 与它们共用技能文件夹 %@，移除后这些智能体也将看不到 Folio 技能。", d.Name, integrator.Display(folder)),
            };
        });
        Bridge.On("ai.revealConfig", a =>
        {
            var config = a.Str("path");
            var path = config.StartsWith('~') ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + config[1..] : config;
            if (File.Exists(path)) Shell.Reveal(path);
            else if (Path.GetDirectoryName(path) is { } folder && Directory.Exists(folder)) Shell.Open(folder);
            return null;
        });
        Bridge.OnAsync("ai.check", async _ =>
        {
            var report = await McpSelfCheck.Run(AiIntegration.CliPath);
            var summary = Loc.S("握手成功（MCP %@），%lld 个工具，用时 %@ 秒", report.ProtocolVersion ?? "?", report.ToolCount, report.Elapsed.TotalSeconds.ToString("F1"));
            return (object?)(report.LibraryProblem is { } problem
                ? new { ok = false, message = summary + Loc.S("；但无法读取文献库：%@", problem) }
                : new { ok = true, message = summary + Loc.S("；文献库中有 %lld 个条目", report.ItemCount ?? 0) });
        });
        Bridge.On("ai.copyConfig", _ =>
        {
            Shell.CopyText(AiIntegration.Integrator.ManualConfiguration);
            M.Toasts.Show(Loc.S("已拷贝 MCP 配置"), "copy");
            return null;
        });
        Bridge.On("ai.exportFolder", _ =>
        {
            if (Pickers.Folder() is not { } folder) return null;
            try { Shell.Reveal(AiIntegration.Integrator.ExportSkill(folder)); }
            catch (Exception e) { M.Toasts.Show(Loc.S("导出失败：%@", e.Message), "warning"); }
            return null;
        });
        Bridge.On("ai.exportZip", _ =>
        {
            if (Pickers.SaveFile(FolioSkill.Name, "ZIP|*.zip") is not { } path) return null;
            try
            {
                var staging = Path.Combine(Path.GetTempPath(), $"folio-skill-{Guid.NewGuid()}");
                var folder = AiIntegration.Integrator.ExportSkill(staging);
                if (File.Exists(path)) File.Delete(path);
                ZipFile.CreateFromDirectory(folder, path, CompressionLevel.Optimal, includeBaseDirectory: true);
                try { Directory.Delete(staging, true); } catch { }
                Shell.Reveal(path);
            }
            catch (Exception e) { M.Toasts.Show(Loc.S("导出失败：%@", e.Message), "warning"); }
            return null;
        });

        // Zotero.
        Bridge.On("zotero.locate", _ => ZoteroLocator.DefaultDataDirectory());
        Bridge.OnAsync("zotero.probe", async a =>
        {
            var dir = a.Str("directory");
            var report = await Task.Run(() => { using var reader = new ZoteroReader(dir); return reader.Probe(); });
            return (object?)new
            {
                regularItems = report.RegularItems, standaloneFiles = report.StandaloneFiles, collections = report.Collections, tags = report.Tags, automaticTags = report.AutomaticTagsAvailable,
                skippedNotes = report.SkippedNotes, skippedAnnotations = report.SkippedAnnotations, skippedSnapshots = report.SkippedSnapshots, skippedTrashed = report.SkippedTrashed,
            };
        });
        Bridge.OnAsync("zotero.import", async a =>
        {
            var dir = a.Str("directory");
            var options = new ZoteroReadOptions { IncludeAutomaticTags = a.Bool("automaticTags") };
            var library = M.Library;
            var autoRename = M.Settings.AutoRenameFiles;
            var window = a.Window;
            var summary = await Task.Run(() =>
            {
                using var reader = new ZoteroReader(dir);
                var (prepared, _) = reader.Read(options);
                return library.ImportPrepared(prepared, autoRename, (done, all) => window?.Bridge.Emit("zotero.progress", new { done, all }));
            });
            M.Importer.IndexFulltext();
            return (object?)new
            {
                itemsImported = summary.ItemsImported, filesImported = summary.FilesImported, groupsCreated = summary.GroupsCreated, tagsCreated = summary.TagsCreated,
                translationsRecognized = summary.TranslationsRecognized, duplicatesSkipped = summary.DuplicatesSkipped, missingFiles = summary.MissingFiles,
            };
        });
    }
}
