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
        run(status, enabled ? "已为 \(status.descriptor.name) 添加 Folio 技能" : "已从 \(status.descriptor.name) 移除 Folio 技能") { integrator in
            try integrator.setSkill(enabled, for: status.descriptor)
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
                let folder = try integrator.exportSkill(to: asZip ? staging : url.deletingLastPathComponent())
                if asZip {
                    let ditto = Process()
                    ditto.executableURL = URL(filePath: "/usr/bin/ditto")
                    ditto.arguments = ["-c", "-k", "--keepParent", folder.path, url.path]
                    try ditto.run()
                    ditto.waitUntilExit()
                    try? FileManager.default.removeItem(at: staging)
                } else if folder.lastPathComponent != url.lastPathComponent {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: folder, to: url)
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
