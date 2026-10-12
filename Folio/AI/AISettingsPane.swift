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
                    Text("没有在这台 Mac 上检测到支持的智能体。").foregroundStyle(.secondary)
                }
                ForEach(integration.detected) { status in
                    AgentRow(status: status, integration: integration)
                }
            } header: {
                HStack {
                    Text("这台 Mac 上的智能体")
                    Spacer()
                    Button {
                        integration.detect()
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("安装了新的智能体后点这里")
                }
            } footer: {
                Text("打开开关即为该智能体添加配置，关闭即移除；修改前会备份原配置文件。改动在重启智能体或开始新会话后生效。")
            }

            if !integration.notDetected.isEmpty {
                Section {
                    Text(integration.notDetected.map(\.descriptor.name).joined(separator: "、"))
                        .foregroundStyle(.secondary)
                } header: {
                    Text("未检测到")
                } footer: {
                    Text("安装后点\"重新检测\"。")
                }
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
                Text("把 MCP 配置粘贴到其他应用（如 Zed、Cherry Studio）的 MCP 设置中；技能包可在 Claude 桌面版 设置 ▸ 功能 ▸ 技能 中上传。")
            }
        }
        .formStyle(.grouped)
        .onAppear { integration.detect() }
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
                toggle("技能", isOn: status.skillInstalled, available: descriptor.skillsFolder != nil,
                       help: descriptor.skillsFolder == nil ? (descriptor.skillNote ?? "不支持技能") : "为 \(descriptor.name) 安装 Folio 技能") {
                    integration.setSkill($0, for: status)
                }
            }
            .disabled(integration.busy.contains(status.id))
        } label: {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.name)
                    if let location = status.location {
                        Text(location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(descriptor.name)
    }

    @ViewBuilder
    private var icon: some View {
        if let location = status.location, location.hasSuffix(".app") {
            Image(nsImage: NSWorkspace.shared.icon(forFile: location))
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "terminal")
                .font(.system(size: 15))
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
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
