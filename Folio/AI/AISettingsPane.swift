import AppKit
import FolioAgent
import SwiftUI

/// 设置 ▸ AI (AI-04): Folio's MCP server and skill, installed per agent with one switch each.
struct AISettingsPane: View {
    @Bindable var settings: AppSettings
    @State private var integration = AIIntegration.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.aiAllowWrites) {
                    Text("允许 AI 修改文献库")
                    Text("关闭后，智能体只能搜索、阅读、引用和导出，不能添加、编辑或移到回收站。AI 不能彻底删除任何内容。")
                }
                LabeledContent {
                    HStack {
                        serverCheckLabel
                        Button("检查") { integration.checkServer() }
                            .disabled(integration.serverCheck == .running)
                    }
                } label: {
                    Text("MCP 服务器")
                    Text("像智能体一样启动 folio-cli，完成握手并读取文献库")
                }
                LabeledContent("命令行工具") {
                    HStack {
                        Text(AIIntegration.cliPath)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: AIIntegration.cliPath)])
                        }
                    }
                }
            } header: {
                Text("Folio 的 AI 接口")
            } footer: {
                Text("智能体通过 MCP 访问你的文献库：查找论文、阅读全文和批注、生成 APA / GB/T 7714 / BibTeX 引用、导入导出 BibTeX / RIS，以及添加和整理文献。Folio 技能教智能体正确地使用这些功能。")
            }

            Section {
                if integration.statuses.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("正在检测…").foregroundStyle(.secondary) }
                } else if integration.detected.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("没有在这台 Mac 上找到可用的智能体")
                        Text("支持 \(AgentIntegrator.catalog.map(\.name).joined(separator: "、"))。安装后点\"重新检测\"。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(integration.detected) { status in
                    AgentRow(status: status, integration: integration)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("这台 Mac 上的智能体")
                    Spacer()
                    if let result = integration.detectionResult {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
                    }
                    Button {
                        integration.detect(userInitiated: true)
                    } label: {
                        Label(integration.isDetecting ? "正在检测…" : "重新检测", systemImage: "arrow.trianglehead.2.clockwise")
                            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: integration.isDetecting)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(integration.isDetecting)
                    .help("重新查找已安装的智能体（安装或卸载后使用）")
                }
                .animation(.smooth(duration: 0.25), value: integration.detectionResult)
            } footer: {
                Text("只列出在这台 Mac 上能运行的智能体：App 完整，或命令能在终端中运行并报告版本。打开开关即按该智能体官方文档的方式添加配置（Claude Code、Codex 使用它们自己的命令），关闭即移除；只改动 Folio 自己的条目，修改前备份原文件。技能放在开放标准的共享文件夹 ~/.agents/skills 时，Codex、Gemini CLI、Cursor CLI 等会共用同一份。改动在重启智能体或开始新会话后生效。")
            }

            Section {
                LabeledContent("其他支持 MCP 的应用") {
                    Button("拷贝 MCP 配置") { integration.copyManualConfiguration() }
                }
                LabeledContent("Folio 技能") {
                    HStack {
                        Button("导出技能文件夹…") { integration.exportSkill(asZip: false, window: NSApp.keyWindow) }
                        Button("导出技能包（.zip）…") { integration.exportSkill(asZip: true, window: NSApp.keyWindow) }
                    }
                }
            } header: {
                Text("手动配置")
            } footer: {
                Text("把 MCP 配置粘贴到其他应用（如 VS Code、Zed、Windsurf、Cherry Studio）的 MCP 设置中；技能包可在 Claude 桌面版 设置 ▸ 功能 ▸ 技能 中上传。")
            }
        }
        .formStyle(.grouped)
        .onAppear { integration.detect() }
    }

    @ViewBuilder
    private var serverCheckLabel: some View {
        switch integration.serverCheck {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .passed(let text):
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(CheckLabelStyle())
        case .warning(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).labelStyle(CheckLabelStyle())
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).labelStyle(CheckLabelStyle())
        }
    }
}

/// A coloured status symbol with secondary, wrapping text.
private struct CheckLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            configuration.icon
            configuration.title.foregroundStyle(.secondary).font(.callout).lineLimit(3).textSelection(.enabled)
        }
        .frame(maxWidth: 420, alignment: .trailing)
    }
}

private struct AgentRow: View {
    let status: AgentStatus
    let integration: AIIntegration

    var body: some View {
        let descriptor = status.descriptor
        // One form row: the agent on the left, its two switches on the right.
        LabeledContent {
            HStack(spacing: 14) {
                if integration.busy.contains(status.id) {
                    ProgressView().controlSize(.small)
                }
                toggle("MCP", isOn: status.mcpInstalled, available: descriptor.mcp != nil,
                       help: status.mcpInstalled ? "Folio 已添加到 \(descriptor.name) 的 MCP 服务器" : "为 \(descriptor.name) 添加 Folio MCP 服务器") {
                    integration.setMCP($0, for: status)
                }
                toggle("技能", isOn: status.skillInstalled, available: descriptor.supportsSkills,
                       help: descriptor.supportsSkills ? "为 \(descriptor.name) 安装 Folio 技能" : (descriptor.skillNote ?? "不支持技能")) {
                    integration.setSkill($0, for: status)
                }
            }
            .disabled(integration.busy.contains(status.id))
        } label: {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.name)
                    if let found {
                        Text(found)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let details {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    if status.mcpInstalled || status.skillInstalled, let hint = AIIntegration.hints[descriptor.id] {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(descriptor.name)
        .contextMenu {
            if status.mcpConfigPath != nil {
                Button("在 Finder 中显示配置文件") { integration.revealConfiguration(status) }
            }
        }
    }

    /// "~/.local/bin/claude · 2.1.3": where the agent is and the version it reported.
    private var found: String? {
        guard let location = status.location else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = location.hasPrefix(home + "/") ? "~" + location.dropFirst(home.count) : location
        return status.version.map { "\(path) · \($0)" } ?? path
    }

    /// Where Folio's entries live for this agent, once installed.
    private var details: String? {
        var parts: [String] = []
        if status.mcpInstalled, let path = status.mcpConfigPath {
            parts.append(status.mcpNeedsUpdate ? "MCP：\(path)（指向的 folio-cli 已不存在）" : "MCP：\(path)")
        }
        if let folder = status.skillFolder {
            parts.append(folder == AgentIntegrator.sharedSkillsFolder ? "技能：~/\(folder)（共享）" : "技能：~/\(folder)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var icon: some View {
        if status.isApp, let location = status.location {
            // App icons carry their own margin; a little larger so they match the tiles.
            Image(nsImage: NSWorkspace.shared.icon(forFile: location))
                .resizable()
                .frame(width: 32, height: 32)
                .padding(-2)
        } else {
            AgentLogoTile(id: status.id)
        }
    }

    /// "MCP ⏻" — the caption beside a small switch (a bare Toggle in a Form would become its own row).
    private func toggle(_ title: String, isOn: Bool, available: Bool, help: String,
                        action: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(available ? .primary : .tertiary)
            Toggle(title, isOn: Binding(get: { isOn }, set: action))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!available)
        }
        .fixedSize()
        .help(help)
    }
}

/// A command-line agent's official logo on an app-icon-like tile, so every row has the same visual weight.
/// Logos that are tiles themselves (Codex, Gemini CLI, Kiro) fill it; plain marks sit on a neutral tile and
/// follow light and dark mode.
struct AgentLogoTile: View {
    let id: String
    @Environment(\.colorScheme) private var colorScheme

    private static let size: CGFloat = 28
    private static let fullBleed: Set<String> = ["codex", "gemini-cli", "kiro"]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.size * 0.24, style: .continuous)
        Group {
            if NSImage(named: "agent-\(id)") == nil {
                Image(systemName: "terminal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if Self.fullBleed.contains(id) {
                Image("agent-\(id)").resizable().interpolation(.high)
            } else {
                Image("agent-\(id)")
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(.primary)
                    .frame(width: Self.size * 0.66, height: Self.size * 0.66)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .background(colorScheme == .dark ? Color(white: 0.20) : Color.white, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 0.5, y: 0.5)
        .accessibilityHidden(true)
    }
}
