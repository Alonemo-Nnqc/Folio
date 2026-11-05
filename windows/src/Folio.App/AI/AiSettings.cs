using System.IO.Compression;
using Folio.Core;
using Folio.Core.Agent;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace Folio.App;

// The macOS AIIntegration and AISettingsPane: Folio's MCP server and skill, installed per agent with one switch each.

static class AiIntegration
{
    /// <summary>folio-cli next to Folio.exe.</summary>
    public static string CliPath => Path.Combine(AppContext.BaseDirectory, "folio-cli.exe");

    public static AgentIntegrator Integrator => new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), CliPath);

    /// <summary>What each agent needs beyond Folio's configuration.</summary>
    public static readonly Dictionary<string, string> Hints = new()
    {
        ["gemini-cli"] = "Gemini CLI 只在受信任的文件夹中启用 MCP 服务器\n首次在某个文件夹中运行时选择信任",
        ["claude-desktop"] = "修改后需要完全退出并重新打开 Claude 桌面版",
        ["copilot-cli"] = "在 Copilot CLI 中输入 /mcp 可查看连接状态",
        ["cursor"] = "与 Cursor 编辑器共用 ~/.cursor/mcp.json，编辑器中也会出现 folio 服务器",
        ["kiro"] = "与 Kiro 编辑器共用 ~/.kiro/settings/mcp.json",
        ["antigravity"] = "在 Antigravity 的 设置 ▸ Customizations 中可看到 folio 服务器\n修改后重新打开 Antigravity",
    };

    static readonly HashSet<string> InlineHints = ["gemini-cli", "claude-desktop"];

    public static bool ShowsInline(string id) => InlineHints.Contains(id);

    /// <summary>At launch: if Folio moved, re-point installed MCP entries and refresh installed skills.</summary>
    public static void RepairAfterLaunch()
    {
        if (!File.Exists(CliPath)) return;
        _ = Task.Run(() =>
        {
            try
            {
                var integrator = Integrator;
                integrator.RepairMovedPaths();
                integrator.RefreshInstalledSkills();
            }
            catch { }
        });
    }
}

static class AiSettings
{
    static List<AgentStatus>? _statuses;

    public static UIElement Page(AppModel model)
    {
        var s = model.Settings;
        var page = new StackPanel { Spacing = 6, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };
        page.Children.Add(SettingsWindow.Header(Loc.S("Folio 的 AI 接口")));
        page.Children.Add(SettingsWindow.Toggle(Loc.S("允许 AI 修改文献库"), s.AiAllowWrites, v => s.AiAllowWrites = v));
        page.Children.Add(SettingsWindow.Note(Loc.S("关闭后只能搜索、阅读和引用\nAI 不能彻底删除任何内容")));

        // MCP server check.
        var checkResult = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = 12, MaxWidth = 440, VerticalAlignment = VerticalAlignment.Center };
        var check = new Button { Content = Loc.S("检查") };
        ToolTipService.SetToolTip(check, Loc.S("像智能体一样启动 folio-cli，完成握手并读取文献库"));
        check.Click += async (_, _) =>
        {
            check.IsEnabled = false;
            checkResult.Text = Loc.S("正在检查…");
            checkResult.Foreground = UI.Brush("FolioSecondaryTextBrush");
            try
            {
                var report = await McpSelfCheck.Run(AiIntegration.CliPath);
                var summary = Loc.S("握手成功（MCP %@），%lld 个工具，用时 %@ 秒", report.ProtocolVersion ?? "?", report.ToolCount, report.Elapsed.TotalSeconds.ToString("F1"));
                if (report.LibraryProblem is { } problem)
                {
                    checkResult.Text = summary + Loc.S("；但无法读取文献库：%@", problem);
                    checkResult.Foreground = UI.Hex("#FF9500");
                }
                else
                {
                    checkResult.Text = summary + Loc.S("；文献库中有 %lld 个条目", report.ItemCount ?? 0);
                    checkResult.Foreground = UI.Hex("#34C759");
                }
            }
            catch (Exception e)
            {
                checkResult.Text = e.Message;
                checkResult.Foreground = UI.Hex("#FF3B30");
            }
            check.IsEnabled = true;
        };
        page.Children.Add(Row(Loc.S("MCP 服务器"), Horizontal(checkResult, check)));
        var cliPath = new TextBlock
        {
            Text = AiIntegration.CliPath, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono,Consolas"), FontSize = 12, IsTextSelectionEnabled = true,
            TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 360, VerticalAlignment = VerticalAlignment.Center, Foreground = UI.Brush("FolioSecondaryTextBrush"),
        };
        var reveal = new Button { Content = Loc.S("在资源管理器中显示") };
        reveal.Click += (_, _) => Shell.Reveal(AiIntegration.CliPath);
        page.Children.Add(Row(Loc.S("命令行工具"), Horizontal(cliPath, reveal)));
        page.Children.Add(SettingsWindow.Note(Loc.S("智能体通过 MCP 查找、阅读、引用和整理你的文献\nFolio 技能教它正确地使用")));

        // Agents.
        var agentsHeader = new Grid { Margin = new Thickness(0, 18, 0, 4) };
        agentsHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        agentsHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = SettingsWindow.Header(Loc.S("这台电脑上的智能体"));
        title.Margin = new Thickness(0);
        agentsHeader.Children.Add(title);
        var redetect = new Button { Content = Loc.S("重新检测") };
        ToolTipService.SetToolTip(redetect, Loc.S("重新查找已安装的智能体（安装或卸载后使用）"));
        Grid.SetColumn(redetect, 1);
        agentsHeader.Children.Add(redetect);
        page.Children.Add(agentsHeader);
        var agents = new StackPanel { Spacing = 2 };
        page.Children.Add(agents);
        page.Children.Add(SettingsWindow.Note(Loc.S("打开开关即按官方方式写入该智能体的配置，关闭即移除，修改前会备份\n重启智能体或开始新会话后生效")));

        void Show(List<AgentStatus>? statuses, bool detecting)
        {
            agents.Children.Clear();
            if (statuses == null || detecting && statuses.Count == 0)
            {
                var busy = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                busy.Children.Add(new ProgressRing { Width = 14, Height = 14, IsActive = true });
                busy.Children.Add(UI.Label(Loc.S("正在检测…"), 13, secondary: true));
                agents.Children.Add(busy);
                return;
            }
            var detected = statuses.Where(x => x.IsDetected).ToList();
            if (detected.Count == 0)
            {
                agents.Children.Add(UI.Label(Loc.S("没有在这台电脑上找到可用的智能体")));
                agents.Children.Add(SettingsWindow.Note(Loc.S("支持 %@\n安装后点\"重新检测\"", string.Join("、", AgentIntegrator.Catalog.Select(d => d.Name)))));
            }
            foreach (var status in detected) agents.Children.Add(AgentRow(model, status, Detect));
        }

        async void Detect(bool userInitiated)
        {
            redetect.IsEnabled = false;
            Show(userInitiated ? null : _statuses, true);
            var started = DateTime.UtcNow;
            var result = await Task.Run(() => AiIntegration.Integrator.Detect());
            // A check that ends in an instant reads as "nothing happened".
            if (userInitiated && DateTime.UtcNow - started < TimeSpan.FromMilliseconds(600)) await Task.Delay(600);
            _statuses = result;
            Show(result, false);
            redetect.IsEnabled = true;
            if (userInitiated)
            {
                int count = result.Count(x => x.IsDetected);
                model.Toasts.Show(count == 0 ? Loc.S("未找到智能体") : Loc.S("找到 %lld 个智能体", count), "refresh");
            }
        }
        redetect.Click += (_, _) => Detect(true);
        Show(_statuses, true);
        Detect(false);

        // Manual configuration.
        page.Children.Add(SettingsWindow.Header(Loc.S("手动配置")));
        var copy = new Button { Content = Loc.S("拷贝 MCP 配置") };
        copy.Click += (_, _) =>
        {
            Shell.CopyText(AiIntegration.Integrator.ManualConfiguration);
            model.Toasts.Show(Loc.S("已拷贝 MCP 配置"), "copy");
        };
        page.Children.Add(Row(Loc.S("其他支持 MCP 的应用"), copy));
        var exportFolder = new Button { Content = Loc.S("导出技能文件夹…") };
        exportFolder.Click += async (_, _) =>
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            Init(picker);
            if (await picker.PickSingleFolderAsync() is not { } folder) return;
            try
            {
                var target = AiIntegration.Integrator.ExportSkill(folder.Path);
                Shell.Reveal(target);
            }
            catch (Exception e) { model.Toasts.Show(Loc.S("导出失败：%@", e.Message), "warning"); }
        };
        var exportZip = new Button { Content = Loc.S("导出技能包（.zip）…") };
        exportZip.Click += async (_, _) =>
        {
            var picker = new FileSavePicker { SuggestedFileName = FolioSkill.Name };
            picker.FileTypeChoices.Add("ZIP", [".zip"]);
            Init(picker);
            if (await picker.PickSaveFileAsync() is not { } file) return;
            try
            {
                var staging = Path.Combine(Path.GetTempPath(), $"folio-skill-{Guid.NewGuid()}");
                var folder = AiIntegration.Integrator.ExportSkill(staging);
                if (File.Exists(file.Path)) File.Delete(file.Path);
                ZipFile.CreateFromDirectory(folder, file.Path, CompressionLevel.Optimal, includeBaseDirectory: true);
                try { Directory.Delete(staging, true); } catch { }
                Shell.Reveal(file.Path);
            }
            catch (Exception e) { model.Toasts.Show(Loc.S("导出失败：%@", e.Message), "warning"); }
        };
        page.Children.Add(Row(Loc.S("Folio 技能"), Horizontal(exportFolder, exportZip)));
        page.Children.Add(SettingsWindow.Note(Loc.S("用于列表之外的应用，如 VS Code、Zed、Windsurf")));
        if (!File.Exists(AiIntegration.CliPath))
            page.Children.Insert(1, SettingsWindow.Note(Loc.S("找不到 folio-cli：%@", AiIntegration.CliPath)));
        return page;
    }

    static void Init(object picker)
    {
        if (((Window?)SettingsWindow.Current ?? App.Current?.Window) is { } window)
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
    }

    static FrameworkElement Row(string title, FrameworkElement control)
    {
        var grid = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 4, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.Children.Add(new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center, MinWidth = 140 });
        control.HorizontalAlignment = HorizontalAlignment.Right;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    static StackPanel Horizontal(params FrameworkElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var c in children) panel.Children.Add(c);
        return panel;
    }

    /// <summary>One agent: its name, where it was found, and its MCP and skill switches.</summary>
    static FrameworkElement AgentRow(AppModel model, AgentStatus status, Action<bool> redetect)
    {
        var d = status.Descriptor;
        var integrator = AiIntegration.Integrator;
        var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 6, 0, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = new StackPanel { Spacing = 2 };
        label.Children.Add(new TextBlock { Text = d.Name });
        if (status.Location is { } location)
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var path = location.StartsWith(home, StringComparison.OrdinalIgnoreCase) ? "~" + location[home.Length..] : location;
            label.Children.Add(new TextBlock
            {
                Text = status.Version != null ? $"{path} · {status.Version}" : path, FontSize = 11, Foreground = UI.Brush("FolioSecondaryTextBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 380,
            });
        }
        if ((status.McpInstalled || status.SkillInstalled) && AiIntegration.ShowsInline(d.Id) && AiIntegration.Hints.TryGetValue(d.Id, out var inline))
            label.Children.Add(new TextBlock { Text = Loc.S(inline), FontSize = 11, TextWrapping = TextWrapping.Wrap, Foreground = UI.Brush("FolioSecondaryTextBrush") });
        grid.Children.Add(label);

        var details = new List<string>();
        if (status.McpInstalled && status.McpConfigPath is { } config)
            details.Add(status.McpNeedsUpdate ? Loc.S("MCP：%@（指向的 folio-cli 已不存在）", config) : Loc.S("MCP：%@", config));
        if (status.SkillFolder is { } skill)
            details.Add(skill == AgentIntegrator.SharedSkillsFolder ? Loc.S("技能：%@（共享）", integrator.Display(skill)) : Loc.S("技能：%@", integrator.Display(skill)));
        if (!AiIntegration.ShowsInline(d.Id) && AiIntegration.Hints.TryGetValue(d.Id, out var hint)) details.Add(Loc.S(hint));
        if (details.Count > 0) ToolTipService.SetToolTip(grid, string.Join("\n", details));

        var switches = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
        var busy = new ProgressRing { Width = 14, Height = 14, IsActive = true, Visibility = Visibility.Collapsed };
        switches.Children.Add(busy);
        ToggleSwitch Switch(string text, bool on, bool available)
        {
            var t = new ToggleSwitch { IsOn = on, IsEnabled = available, OnContent = text, OffContent = text, MinWidth = 0 };
            switches.Children.Add(t);
            return t;
        }
        var mcp = Switch("MCP", status.McpInstalled, d.Mcp != null);
        var skillSwitch = Switch(Loc.S("技能"), status.SkillInstalled, d.SupportsSkills);
        if (!d.SupportsSkills) ToolTipService.SetToolTip(skillSwitch, d.SkillNote ?? Loc.S("不支持技能"));

        async Task Change(Action<AgentIntegrator> work, string success, ToggleSwitch toggle, bool previous)
        {
            busy.Visibility = Visibility.Visible;
            mcp.IsEnabled = skillSwitch.IsEnabled = false;
            string? error = null;
            await Task.Run(() => { try { work(integrator); } catch (Exception e) { error = e.Message; } });
            busy.Visibility = Visibility.Collapsed;
            if (error != null)
            {
                await Dialogs.Message(Loc.S("无法修改 %@ 的配置", d.Name), error);
                toggle.IsOn = previous;
            }
            else model.Toasts.Show(success + Loc.S("，重启该智能体或开始新会话后生效"), "checkmark");
            redetect(false);
        }
        bool settling = false;
        mcp.Toggled += async (_, _) =>
        {
            if (settling || mcp.IsOn == status.McpInstalled) return;
            bool on = mcp.IsOn;
            await Change(i => i.SetMcp(on, d), on ? Loc.S("已为 %@ 添加 Folio MCP", d.Name) : Loc.S("已从 %@ 移除 Folio MCP", d.Name), mcp, !on);
        };
        skillSwitch.Toggled += async (_, _) =>
        {
            if (settling || skillSwitch.IsOn == status.SkillInstalled) return;
            bool on = skillSwitch.IsOn;
            if (!on)
            {
                // The skill may live in a folder other agents read too (~/.agents/skills, ~/.claude/skills).
                var detected = (_statuses ?? []).Where(x => x.IsDetected).Select(x => x.Id).ToHashSet();
                var losing = integrator.AgentsLosingSkill(d).Where(x => detected.Contains(x.Id)).ToList();
                if (losing.Count > 0 && !await Dialogs.Confirm(Loc.S("同时从 %@ 移除 Folio 技能？", string.Join("、", losing.Select(x => x.Name))),
                        Loc.S("%@ 与它们共用技能文件夹 %@，移除后这些智能体也将看不到 Folio 技能。", d.Name, integrator.Display(status.SkillFolder ?? "")), Loc.S("移除"), Loc.S("取消")))
                {
                    settling = true;
                    skillSwitch.IsOn = true;
                    settling = false;
                    return;
                }
            }
            await Change(i => i.SetSkill(on, d), on ? Loc.S("已为 %@ 添加 Folio 技能", d.Name) : Loc.S("已从 %@ 移除 Folio 技能", d.Name), skillSwitch, !on);
        };
        Grid.SetColumn(switches, 1);
        grid.Children.Add(switches);

        if (status.McpConfigPath != null)
        {
            var menu = new MenuFlyout();
            menu.Items.Add(UI.Item(Loc.S("在资源管理器中显示配置文件"), () =>
            {
                var path = status.McpConfigPath!.StartsWith('~') ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) + status.McpConfigPath[1..] : status.McpConfigPath;
                if (File.Exists(path)) Shell.Reveal(path);
                else if (Path.GetDirectoryName(path) is { } folder && Directory.Exists(folder)) Shell.Open(folder);
            }, "open"));
            grid.ContextFlyout = menu;
        }
        return grid;
    }
}
