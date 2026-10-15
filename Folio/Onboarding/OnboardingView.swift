import AppKit
import FolioAgent
import SwiftUI

/// The guide's pages and the bar under them (page dots, 返回, 继续).
struct OnboardingView: View {
    @Bindable var state: OnboardingState
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch state.step {
                case .welcome: WelcomePage(state: state)
                case .zotero: ZoteroPage(state: state)
                case .browser: BrowserPage(state: state)
                case .agents: AgentsPage(state: state)
                case .translation: TranslationPage(state: state)
                case .done: DonePage(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(state.step)
            .transition(.opacity)
            Divider()
            bottomBar
        }
        .animation(.smooth(duration: 0.2), value: state.step)
        .frame(width: 720, height: 640)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if state.isFirst {
                Button("跳过设置", action: close)
            } else {
                Button("返回", action: state.back)
            }
            Spacer()
            PageDots(steps: state.steps, current: state.step)
            Spacer()
            if state.isFirst {
                Button("开始设置", action: state.next)
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
            } else if state.isLast {
                Button("开始使用", action: close)
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
            } else {
                Button("继续", action: state.next)
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

private struct PageDots: View {
    let steps: [OnboardingStep]
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 7) {
            ForEach(steps, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: step == current ? 18 : 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Icon, title and one line of explanation at the top of every page but the first.
private struct PageHeader<Icon: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let icon: Icon

    var body: some View {
        VStack(spacing: 10) {
            icon.frame(width: 64, height: 64)
            Text(title).font(.title.weight(.semibold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 540)
        }
        .padding(.top, 34)
        .padding(.bottom, 8)
    }
}

/// An SF Symbol on a tinted rounded square, for pages without an app icon to show.
private struct SymbolTile: View {
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(tint.gradient)
            .overlay(Image(systemName: symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(.white))
            .frame(width: 60, height: 60)
    }
}

/// A large choice: icon, title, explanation, and the whole card is the button.
private struct ChoiceCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(prominent ? Color.accentColor : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(prominent ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.2), lineWidth: prominent ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    let state: OnboardingState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("欢迎使用 Folio")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 10)
            Text("轻量、原生的 Mac 文献管理软件")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            Grid(alignment: .topLeading, horizontalSpacing: 36, verticalSpacing: 22) {
                GridRow {
                    feature("doc.text.magnifyingglass", "自动识别", "拖入 PDF，自动检索标题、作者、期刊和 DOI")
                    feature("highlighter", "阅读与批注", "批注直接写回 PDF，与“预览”互通")
                }
                GridRow {
                    feature("character.book.closed", "保留排版的翻译", "整篇翻译，原文与译文并排阅读")
                    feature("sparkles", "AI 接入", "让 Claude Code、Codex 等智能体查找和引用你的文献")
                }
            }
            .frame(maxWidth: 580)
            .padding(.top, 34)
            Spacer(minLength: 24)
            Text("接下来用一分钟完成几项设置，每一步都可以跳过，之后也能在设置中更改。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("文献库保存在 \((state.model.library.root.path as NSString).abbreviatingWithTildeInPath)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 40)
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 270, alignment: .leading)
    }
}

// MARK: - Zotero

private struct ZoteroPage: View {
    @Bindable var state: OnboardingState
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "从 Zotero 导入？", subtitle: "在这台 Mac 上找到了 Zotero 文献库") {
                if let zotero = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.zotero.zotero") {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: zotero.path)).resizable()
                } else {
                    SymbolTile(symbol: "books.vertical", tint: .red)
                }
            }
            summary.padding(.bottom, 20)
            VStack(spacing: 12) {
                if state.zoteroImported {
                    Label("已从 Zotero 导入，Folio 文献库中现在有 \(state.model.snapshot.items.count) 个条目", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(.vertical, 8)
                } else {
                    ChoiceCard(symbol: "square.and.arrow.down.on.square", title: "从 Zotero 导入",
                               detail: "导入条目、PDF、分组和标签。只读取 Zotero 数据库的副本，不会修改 Zotero，两个软件可以同时使用", prominent: true) {
                        importing = true
                    }
                }
                ChoiceCard(symbol: "sparkles.rectangle.stack", title: state.zoteroImported ? "继续" : "直接开始使用",
                           detail: "从空的文献库开始；以后可以随时在 文件 ▸ 从 Zotero 导入… 中导入", action: state.next)
            }
            .frame(maxWidth: 520)
            Spacer()
        }
        .padding(.horizontal, 40)
        .sheet(isPresented: $importing, onDismiss: { state.zoteroImported = !state.model.snapshot.items.isEmpty }) {
            ZoteroImportSheet(model: state.model)
                .environment(\.sheetDismiss, SheetDismissAction { importing = false })
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let report = state.zoteroReport {
            Text("\(report.regularItems) 个条目 · \(report.collections) 个分组 · \(report.tags) 个标签")
                .font(.headline)
        } else if let problem = state.zoteroProblem {
            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在读取 Zotero 文献库…").foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Browser extension

private struct BrowserPage: View {
    let state: OnboardingState
    @State private var guide: BrowserInfo?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "安装浏览器插件", subtitle: "在论文页面点一下，就能把论文和 PDF 保存到 Folio") {
                if let browser = state.defaultBrowser {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: browser.appURL.path)).resizable()
                } else {
                    SymbolTile(symbol: "safari")
                }
            }
            VStack(spacing: 12) {
                if let browser = state.defaultBrowser {
                    row(browser, isDefault: true)
                }
                let others = state.browsers.filter { $0.id != state.defaultBrowser?.id }
                if !others.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(others) { browser in
                            row(browser, isDefault: false)
                            if browser.id != others.last?.id { Divider().padding(.leading, 52) }
                        }
                    }
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
                }
            }
            .frame(maxWidth: 560)
            .padding(.top, 12)
            Spacer(minLength: 12)
            Text("扩展尚未上架应用商店，Folio 会一步步带你完成安装，约需一分钟。之后可以在 设置 ▸ 浏览器 中管理。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 40)
        .task { await state.refreshBrowsers() }
        .sheet(item: $guide, onDismiss: { Task { await state.refreshBrowsers() } }) { browser in
            ExtensionInstallGuide(browser: browser, model: state.model)
        }
    }

    @ViewBuilder
    private func row(_ browser: BrowserInfo, isDefault: Bool) -> some View {
        let enabled = state.enabledBrowsers.contains(browser.id)
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: browser.appURL.path))
                .resizable()
                .frame(width: isDefault ? 44 : 30, height: isDefault ? 44 : 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.name).font(isDefault ? .headline : .body)
                if isDefault { Text("你的默认浏览器").font(.callout).foregroundStyle(.secondary) }
            }
            Spacer()
            if enabled {
                Label("已启用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if isDefault {
                Button(browser.family == .safari ? "启用 Folio 扩展…" : "安装 Folio 扩展…") { guide = browser }
                    .glassProminentButtonStyle()
                    .controlSize(.large)
            } else {
                Button(browser.family == .safari ? "启用…" : "安装…") { guide = browser }
            }
        }
        .padding(isDefault ? 16 : 11)
        .background {
            if isDefault {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary)
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Agents

private struct AgentsPage: View {
    let state: OnboardingState

    var body: some View {
        @Bindable var settings = state.model.settings
        let integration = state.integration
        VStack(spacing: 0) {
            PageHeader(title: "让 AI 智能体使用你的文献库",
                       subtitle: "为这台 Mac 上的智能体添加 Folio 的 MCP 服务器和技能，之后就能让它们查找、阅读和引用你的论文") {
                SymbolTile(symbol: "sparkles", tint: .purple)
            }
            Form {
                Section {
                    ForEach(integration.detected) { status in
                        AgentRow(status: status, integration: integration)
                    }
                } header: {
                    HStack {
                        Text("找到 \(integration.detected.count) 个智能体")
                        Spacer()
                        Button("全部添加") { integration.enableAll() }
                            .disabled(!integration.hasPendingSetup || !integration.busy.isEmpty)
                    }
                } footer: {
                    Text("按各智能体官方的方式写入配置，修改前会备份；重启智能体或开始新会话后生效")
                }
                Section {
                    Toggle(isOn: $settings.aiAllowWrites) {
                        Text("允许 AI 修改文献库")
                        Text("关闭后只能搜索、阅读和引用\nAI 不能彻底删除任何内容")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 620)
        }
        .padding(.horizontal, 30)
    }
}

// MARK: - Translation

private struct TranslationPage: View {
    let state: OnboardingState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置整篇翻译", subtitle: "保留排版、公式和图表的全文翻译，由开源引擎 pdf2zh_next 完成") {
                SymbolTile(symbol: "character.book.closed", tint: .orange)
            }
            Form {
                Section {
                    engine
                } header: {
                    Text("翻译组件")
                }
                ServiceSection(model: state.model, compact: true)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 620)
        }
        .padding(.horizontal, 30)
    }

    @ViewBuilder
    private var engine: some View {
        let coordinator = state.model.translations
        if case .installing(let progress) = coordinator.installState {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progress.phase.title)
                    Spacer()
                    Button("取消安装") { coordinator.cancelInstall() }
                }
                ProgressView(value: progress.fractionCompleted)
                Text("安装在后台进行，可以继续下一步").font(.caption).foregroundStyle(.secondary)
            }
        } else if state.usesOwnTranslator {
            Label {
                Text("使用这台 Mac 上的 pdf2zh_next")
                Text(TranslationSettingsPane.abbreviatedPath(state.model.settings.translatorCustomPath))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else if state.builtInInstalled {
            Label("内置翻译组件已安装", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            discovery
            if case .failed(let message) = coordinator.installState {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var discovery: some View {
        let coordinator = state.model.translations
        switch state.discovery {
        case .idle, .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在查找这台 Mac 上已安装的 pdf2zh_next…").foregroundStyle(.secondary)
            }
        case .found(let url, let version):
            LabeledContent {
                Button("使用它", action: state.useFoundTranslator).glassProminentButtonStyle()
            } label: {
                Text("找到 pdf2zh_next \(version)")
                Text(TranslationSettingsPane.abbreviatedPath(url.path))
            }
            LabeledContent("也可以使用 Folio 内置的组件（约 1.4 GB）") {
                Button("下载内置组件") { coordinator.install() }
            }
        case .notFound:
            LabeledContent {
                Button("下载并安装") { coordinator.install() }.glassProminentButtonStyle()
            } label: {
                Text("没有找到已安装的 pdf2zh_next")
                Text("下载 Folio 内置的组件，约 1.4 GB，只需一次")
            }
            LabeledContent("已经安装过，但 Folio 没找到？") {
                Button("手动选择…", action: state.chooseTranslator)
            }
            if !state.integration.detected.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("也可以让智能体帮你找：在已添加 Folio MCP 的智能体中发送下面这句话")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .top) {
                        Text(OnboardingState.agentPrompt)
                            .font(.callout)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        Button("拷贝") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(OnboardingState.agentPrompt, forType: .string)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Done

private struct DonePage: View {
    let state: OnboardingState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "一切就绪", subtitle: "现在可以开始整理你的文献了") {
                SymbolTile(symbol: "checkmark", tint: .green)
            }
            VStack(alignment: .leading, spacing: 12) {
                summaryRow(browserDone, browserText)
                if !state.integration.detected.isEmpty { summaryRow(agentsDone, agentsText) }
                summaryRow(translationDone, translationText)
                if state.zoteroDirectory != nil, state.zoteroImported {
                    summaryRow(true, String(localized: "已从 Zotero 导入"))
                }
            }
            .padding(18)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                tip("tray.and.arrow.down", "把 PDF 拖进窗口即可添加文献")
                tip("command", "在浏览器的论文页面按 ⌘⇧S 保存到 Folio")
                tip("questionmark.circle", "随时可以在 帮助 ▸ 欢迎使用 Folio 中重新打开本向导")
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.top, 22)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var browserDone: Bool { !state.enabledBrowsers.isEmpty }
    private var browserText: String {
        let names = state.browsers.filter { state.enabledBrowsers.contains($0.id) }.map(\.name)
        return names.isEmpty ? String(localized: "浏览器插件未安装，可在 设置 ▸ 浏览器 中安装")
            : String(localized: "浏览器插件已在 \(names.joined(separator: String(localized: "、"))) 中启用")
    }

    private var agentsDone: Bool { state.integration.detected.contains { $0.mcpInstalled } }
    private var agentsText: String {
        let count = state.integration.detected.filter(\.mcpInstalled).count
        return count == 0 ? String(localized: "还没有为智能体添加 Folio MCP，可在 设置 ▸ AI 中添加")
            : String(localized: "\(count) 个智能体已添加 Folio MCP")
    }

    private var translationDone: Bool { state.usesOwnTranslator || state.builtInInstalled }
    private var translationText: String {
        if case .installing(let progress) = state.model.translations.installState {
            return String(localized: "翻译组件正在后台下载（\(Int(progress.fractionCompleted * 100))%）")
        }
        if translationDone { return String(localized: "翻译组件已就绪") }
        return String(localized: "翻译组件未安装，第一次翻译时会提示下载")
    }

    private func summaryRow(_ done: Bool, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Color.green : Color.secondary)
        }
    }

    private func tip(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
    }
}
