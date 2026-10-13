import AppKit
import FolioAgent
import Observation

/// State behind 设置 ▸ AI (AI-04): which agents are on this Mac and whether Folio's MCP server and
/// skill are installed for each. The agents' own configuration files are the source of truth.
@Observable
final class AIIntegration {
    static let shared = AIIntegration()

    private(set) var statuses: [AgentStatus] = []
    /// Agent ids with an install / remove in progress.
    private(set) var busy: Set<String> = []
    private(set) var lastDetection: Date?
    private(set) var serverCheck = ServerCheck.idle

    enum ServerCheck: Equatable {
        case idle
        case running
        case passed(String)
        case warning(String)
        case failed(String)
    }

    /// What each agent needs beyond Folio's configuration, shown under its row.
    static let hints: [String: String] = [
        "gemini-cli": "Gemini CLI 只在受信任的文件夹中启用 MCP 服务器：首次在某个文件夹中运行时选择信任。",
        "claude-desktop": "修改后需要完全退出并重新打开 Claude 桌面版。",
        "vscode": "在 Copilot 对话的 Agent 模式中使用；首次启动服务器时 VS Code 会请你确认。",
        "copilot-cli": "在 Copilot CLI 中输入 /mcp 可查看连接状态。",
        "zed": "在 Agent 面板的设置中可看到 folio 服务器状态。",
        "antigravity": "如果是新版 Antigravity，在 设置 ▸ Customizations 中可看到 folio 服务器。",
    ]

    /// folio-cli inside this copy of Folio.app.
    static var cliPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/folio-cli").path
    }

    var integrator: AgentIntegrator { AgentIntegrator(cliPath: Self.cliPath) }

    var detected: [AgentStatus] { statuses.filter(\.isDetected) }
    var notDetected: [AgentStatus] { statuses.filter { !$0.isDetected } }

    func detect() {
        let integrator = self.integrator
        Task {
            let result = await Task.detached { integrator.detect() }.value
            statuses = result
            lastDetection = Date()
        }
    }

    func setMCP(_ enabled: Bool, for status: AgentStatus) {
        run(status, enabled ? "已为 \(status.descriptor.name) 添加 Folio MCP" : "已从 \(status.descriptor.name) 移除 Folio MCP") { integrator in
            try integrator.setMCP(enabled, for: status.descriptor)
        }
    }

    func setSkill(_ enabled: Bool, for status: AgentStatus) {
        if !enabled {
            // The skill may live in a folder other agents read too (~/.agents/skills, ~/.claude/skills).
            let detected = Set(statuses.filter(\.isDetected).map(\.id))
            let losing = integrator.agentsLosingSkill(ifRemovedFor: status.descriptor).filter { detected.contains($0.id) }
            if !losing.isEmpty {
                let alert = NSAlert()
                alert.messageText = "同时从 \(losing.map(\.name).joined(separator: "、")) 移除 Folio 技能？"
                alert.informativeText = "\(status.descriptor.name) 与它们共用技能文件夹 ~/\(status.skillFolder ?? "")，移除后这些智能体也将看不到 Folio 技能。"
                alert.addButton(withTitle: "移除")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        run(status, enabled ? "已为 \(status.descriptor.name) 添加 Folio 技能" : "已从 \(status.descriptor.name) 移除 Folio 技能") { integrator in
            try integrator.setSkill(enabled, for: status.descriptor)
        }
    }

    /// Starts folio-cli like an agent would and reports what it answered (设置 ▸ AI ▸ 检查).
    func checkServer() {
        serverCheck = .running
        let cli = Self.cliPath
        Task {
            do {
                let report = try await MCPSelfCheck.run(cliPath: cli)
                let seconds = Double(report.elapsed.components.attoseconds) / 1e18 + Double(report.elapsed.components.seconds)
                let summary = "握手成功（MCP \(report.protocolVersion ?? "?")），\(report.toolCount) 个工具，用时 \(String(format: "%.1f", seconds)) 秒"
                if let problem = report.libraryProblem {
                    serverCheck = .warning(summary + "；但无法读取文献库：\(problem)")
                } else {
                    serverCheck = .passed(summary + "；文献库中有 \(report.itemCount ?? 0) 个条目")
                }
            } catch {
                serverCheck = .failed(error.localizedDescription)
            }
        }
    }

    /// Reveals an agent's configuration file (or its folder when the file does not exist yet).
    func revealConfiguration(_ status: AgentStatus) {
        guard let path = status.mcpConfigPath else { return }
        let url = URL(filePath: (path as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func run(_ status: AgentStatus, _ success: String, _ work: @escaping @Sendable (AgentIntegrator) throws -> Void) {
        let integrator = self.integrator
        busy.insert(status.id)
        Task {
            let error = await Task.detached { () -> String? in
                do { try work(integrator); return nil } catch { return error.localizedDescription }
            }.value
            busy.remove(status.id)
            statuses = await Task.detached { integrator.detect() }.value
            let model = AppDelegate.shared.model
            if let error {
                let alert = NSAlert()
                alert.messageText = "无法修改 \(status.descriptor.name) 的配置"
                alert.informativeText = error
                alert.runModal()
            } else {
                model?.toasts.show(success + "，重启该智能体或开始新会话后生效", systemImage: "checkmark.circle")
            }
        }
    }

    /// Copies the generic MCP configuration for agents Folio does not know.
    func copyManualConfiguration() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(integrator.manualConfiguration, forType: .string)
        AppDelegate.shared.model?.toasts.show("已拷贝 MCP 配置", systemImage: "doc.on.clipboard")
    }

    /// Writes the skill folder, or a .zip of it (Claude 桌面版 uploads skills as zip files).
    func exportSkill(asZip: Bool, window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = asZip ? "\(FolioSkill.name).zip" : FolioSkill.name
        panel.allowedContentTypes = asZip ? [.zip] : [.folder]
        panel.message = asZip ? "导出 Folio 技能包，可在 Claude 桌面版 设置 ▸ 功能 ▸ 技能 中上传" : "导出 Folio 技能文件夹（含 SKILL.md）"
        let handler = { [self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            do {
                let staging = FileManager.default.temporaryDirectory.appending(path: "folio-skill-\(UUID().uuidString)")
                let folder = try integrator.exportSkill(to: staging)
                if asZip {
                    let ditto = Process()
                    ditto.executableURL = URL(filePath: "/usr/bin/ditto")
                    ditto.arguments = ["-c", "-k", "--keepParent", folder.path, url.path]
                    try ditto.run()
                    ditto.waitUntilExit()
                    try? FileManager.default.removeItem(at: staging)
                } else {
                    // The save panel already confirmed replacing an existing folder.
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    try FileManager.default.moveItem(at: folder, to: url)
                    try? FileManager.default.removeItem(at: staging)
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                AppDelegate.shared.model?.toasts.show("导出失败：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// At launch: if Folio.app moved, re-point installed MCP entries and refresh installed skills.
    static func repairAfterLaunch() {
        guard !UserDefaults.standard.bool(forKey: "FolioUITesting") else { return }
        let integrator = AgentIntegrator(cliPath: cliPath)
        Task.detached(priority: .utility) {
            integrator.repairMovedPaths()
            integrator.refreshInstalledSkills()
        }
    }
}
