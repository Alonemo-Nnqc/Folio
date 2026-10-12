import Foundation

/// An AI agent Folio can configure (AI-04).
public struct AgentDescriptor: Sendable, Identifiable, Hashable {
    public enum MCPTarget: Sendable, Hashable {
        /// `claude mcp add --scope user` (falls back to `~/.claude.json` → mcpServers).
        case claudeCode
        /// `codex mcp add` (falls back to `~/.codex/config.toml` → [mcp_servers.folio]).
        case codex
        /// A JSON file (path relative to home) with servers under `key`.
        case json(path: String, key: String, style: EntryStyle)
    }

    public enum EntryStyle: Sendable, Hashable {
        /// `{"command": …, "args": […]}` (Claude Desktop, Cursor, Gemini, Windsurf, Cline, LM Studio, Kiro).
        case standard
        /// VS Code: `{"type": "stdio", "command": …, "args": […]}`.
        case vscode
        /// opencode: `{"type": "local", "command": [cli, "mcp"], "enabled": true}`.
        case opencode
    }

    public let id: String
    public let name: String
    /// App bundles (in /Applications or ~/Applications) that mean the agent is installed.
    public let apps: [String]
    /// Command-line tools that mean the agent is installed.
    public let commands: [String]
    /// Paths relative to home whose existence means the agent is installed.
    public let markers: [String]
    public let mcp: MCPTarget?
    /// Skills folder relative to home (`<folder>/folio-library/SKILL.md`), when the agent supports skills.
    public let skillsFolder: String?
    /// Why the skill switch is unavailable, or how to add it by hand.
    public let skillNote: String?
}

/// Detected state of one agent.
public struct AgentStatus: Sendable, Identifiable, Hashable {
    public let descriptor: AgentDescriptor
    public var id: String { descriptor.id }
    public let isDetected: Bool
    /// Where it was found (app path, command path or config folder).
    public let location: String?
    public let mcpInstalled: Bool
    public let skillInstalled: Bool
    /// The installed MCP entry points at another copy of folio-cli (Folio was moved).
    public let mcpNeedsUpdate: Bool
}

public struct AgentIntegrationError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Detects agents and adds / removes Folio's MCP server and skill in their configuration.
public struct AgentIntegrator: Sendable {
    public static let serverName = "folio"

    public let home: URL
    /// Absolute path of folio-cli inside Folio.app.
    public let cliPath: String
    /// Use the agents' own CLIs (`claude mcp add` …) when present. Tests turn this off.
    public var useAgentCommands: Bool
    var applicationFolders: [URL]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, cliPath: String, useAgentCommands: Bool = true) {
        self.home = home
        self.cliPath = cliPath
        self.useAgentCommands = useAgentCommands
        applicationFolders = [URL(filePath: "/Applications"), home.appending(path: "Applications")]
    }

    public static let catalog: [AgentDescriptor] = [
        .init(id: "claude-code", name: "Claude Code", apps: [], commands: ["claude"], markers: [".claude"],
              mcp: .claudeCode, skillsFolder: ".claude/skills", skillNote: nil),
        .init(id: "claude-desktop", name: "Claude 桌面版", apps: ["Claude.app"], commands: [],
              markers: ["Library/Application Support/Claude"],
              mcp: .json(path: "Library/Application Support/Claude/claude_desktop_config.json", key: "mcpServers", style: .standard),
              skillsFolder: nil, skillNote: "Claude 桌面版的技能需在 设置 ▸ 功能 ▸ 技能 中上传，可用下方\"导出技能包…\"生成。"),
        .init(id: "codex", name: "Codex", apps: ["Codex.app"], commands: ["codex"], markers: [".codex"],
              mcp: .codex, skillsFolder: ".codex/skills", skillNote: nil),
        .init(id: "gemini-cli", name: "Gemini CLI", apps: [], commands: ["gemini"], markers: [".gemini"],
              mcp: .json(path: ".gemini/settings.json", key: "mcpServers", style: .standard),
              skillsFolder: ".gemini/skills", skillNote: nil),
        .init(id: "cursor", name: "Cursor", apps: ["Cursor.app"], commands: ["cursor"], markers: [".cursor"],
              mcp: .json(path: ".cursor/mcp.json", key: "mcpServers", style: .standard),
              skillsFolder: ".cursor/skills", skillNote: nil),
        .init(id: "vscode", name: "VS Code（Copilot）", apps: ["Visual Studio Code.app"], commands: ["code"],
              markers: ["Library/Application Support/Code/User"],
              mcp: .json(path: "Library/Application Support/Code/User/mcp.json", key: "servers", style: .vscode),
              skillsFolder: nil, skillNote: "VS Code 不支持全局技能，可通过 MCP 使用 Folio。"),
        .init(id: "windsurf", name: "Windsurf", apps: ["Windsurf.app"], commands: ["windsurf"], markers: [".codeium/windsurf"],
              mcp: .json(path: ".codeium/windsurf/mcp_config.json", key: "mcpServers", style: .standard),
              skillsFolder: nil, skillNote: "Windsurf 不支持技能，可通过 MCP 使用 Folio。"),
        .init(id: "cline", name: "Cline", apps: [], commands: [],
              markers: ["Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"],
              mcp: .json(path: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
                         key: "mcpServers", style: .standard),
              skillsFolder: nil, skillNote: "Cline 不支持技能，可通过 MCP 使用 Folio。"),
        .init(id: "opencode", name: "opencode", apps: [], commands: ["opencode"], markers: [".config/opencode"],
              mcp: .json(path: ".config/opencode/opencode.json", key: "mcp", style: .opencode),
              skillsFolder: nil, skillNote: "opencode 会读取 Claude Code 的技能目录，为 Claude Code 打开技能即可。"),
        .init(id: "lm-studio", name: "LM Studio", apps: ["LM Studio.app"], commands: ["lms"], markers: [".lmstudio"],
              mcp: .json(path: ".lmstudio/mcp.json", key: "mcpServers", style: .standard),
              skillsFolder: nil, skillNote: "LM Studio 不支持技能，可通过 MCP 使用 Folio。"),
        .init(id: "kiro", name: "Kiro", apps: ["Kiro.app"], commands: ["kiro"], markers: [".kiro"],
              mcp: .json(path: ".kiro/settings/mcp.json", key: "mcpServers", style: .standard),
              skillsFolder: nil, skillNote: "Kiro 不支持技能，可通过 MCP 使用 Folio。"),
    ]

    // MARK: Detection

    public func detect() -> [AgentStatus] {
        Self.catalog.map(status)
    }

    public func status(of descriptor: AgentDescriptor) -> AgentStatus {
        let location = locate(descriptor)
        let entry = installedCommand(descriptor)
        return AgentStatus(descriptor: descriptor, isDetected: location != nil, location: location,
                           mcpInstalled: entry != nil, skillInstalled: skillInstalled(descriptor),
                           mcpNeedsUpdate: entry.map { $0 != cliPath } ?? false)
    }

    private func locate(_ descriptor: AgentDescriptor) -> String? {
        for app in descriptor.apps {
            for folder in applicationFolders {
                let url = folder.appending(path: app)
                if FileManager.default.fileExists(atPath: url.path) { return url.path }
            }
        }
        for command in descriptor.commands {
            if let path = Self.findCommand(command, home: home) { return path }
        }
        for marker in descriptor.markers {
            let url = home.appending(path: marker)
            if FileManager.default.fileExists(atPath: url.path) { return "~/" + marker }
        }
        return nil
    }

    /// Where command-line agents are usually installed (an app launched from Finder has no shell PATH).
    static func searchPath(home: URL) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", home.appending(path: ".local/bin").path,
         home.appending(path: ".npm-global/bin").path, home.appending(path: ".bun/bin").path,
         home.appending(path: ".volta/bin").path, home.appending(path: "Library/pnpm").path,
         home.appending(path: ".cargo/bin").path]
    }

    static func findCommand(_ name: String, home: URL) -> String? {
        searchPath(home: home).map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: MCP

    /// The folio-cli path currently configured for the agent, or nil when Folio's server is absent.
    func installedCommand(_ descriptor: AgentDescriptor) -> String? {
        switch descriptor.mcp {
        case nil:
            return nil
        case .claudeCode:
            return command(inJSON: ".claude.json", key: "mcpServers", style: .standard)
        case .codex:
            return codexCommand()
        case let .json(path, key, style):
            return command(inJSON: path, key: key, style: style)
        }
    }

    public func setMCP(_ enabled: Bool, for descriptor: AgentDescriptor) throws {
        switch descriptor.mcp {
        case nil:
            throw AgentIntegrationError(message: "\(descriptor.name) 不支持 MCP。")
        case .claudeCode:
            let args = enabled ? ["mcp", "add", "--scope", "user", Self.serverName, "--", cliPath, "mcp"]
                : ["mcp", "remove", "--scope", "user", Self.serverName]
            if enabled { try? runAgentCommand("claude", ["mcp", "remove", "--scope", "user", Self.serverName]) }
            if try !runAgentCommand("claude", args) {
                try editJSON(".claude.json", key: "mcpServers", style: .standard, enabled: enabled)
            }
        case .codex:
            if enabled { try? runAgentCommand("codex", ["mcp", "remove", Self.serverName]) }
            let args = enabled ? ["mcp", "add", Self.serverName, "--", cliPath, "mcp"] : ["mcp", "remove", Self.serverName]
            if try !runAgentCommand("codex", args) {
                try editCodexTOML(enabled: enabled)
            }
        case let .json(path, key, style):
            try editJSON(path, key: key, style: style, enabled: enabled)
        }
        // Trust but verify: the agent's own tool may have written somewhere else.
        if (installedCommand(descriptor) != nil) != enabled {
            throw AgentIntegrationError(message: "未能\(enabled ? "添加" : "移除") \(descriptor.name) 的配置，请检查其配置文件。")
        }
    }

    /// Re-points configured agents at the current folio-cli (after Folio.app moved). Returns their names.
    @discardableResult
    public func repairMovedPaths() -> [String] {
        detect().filter(\.mcpNeedsUpdate).compactMap { status in
            (try? setMCP(true, for: status.descriptor)).map { status.descriptor.name }
        }
    }

    /// The JSON entry other agents need, for "复制 MCP 配置".
    public var manualConfiguration: String {
        let entry: JSONValue = ["mcpServers": [Self.serverName: ["command": .string(cliPath), "args": ["mcp"]]]]
        return entry.encoded(pretty: true)
    }

    /// Runs an agent's CLI; false when the CLI is not installed or commands are off.
    @discardableResult
    func runAgentCommand(_ name: String, _ arguments: [String]) throws -> Bool {
        guard useAgentCommands, let path = Self.findCommand(name, home: home) else { return false }
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Node-based CLIs need their runtime on PATH even when Folio was opened from Finder.
        environment["PATH"] = (Self.searchPath(home: home) + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["HOME"] = home.path
        if environment["CODEX_HOME"] == nil { environment["CODEX_HOME"] = home.appending(path: ".codex").path }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            // "not found" when removing something absent is fine.
            if arguments.contains("remove") { return true }
            throw AgentIntegrationError(message: "\(name) \(arguments.prefix(2).joined(separator: " ")) 失败：\(text.prefix(300))")
        }
        return true
    }

    // MARK: JSON configuration files

    private func command(inJSON path: String, key: String, style: AgentDescriptor.EntryStyle) -> String? {
        let url = home.appending(path: path)
        guard let data = FileManager.default.contents(atPath: url.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root[key] as? [String: Any], let entry = servers[Self.serverName] as? [String: Any] else { return nil }
        if style == .opencode { return (entry["command"] as? [String])?.first }
        return entry["command"] as? String
    }

    func editJSON(_ path: String, key: String, style: AgentDescriptor.EntryStyle, enabled: Bool) throws {
        let url = home.appending(path: path)
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: url.path), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentIntegrationError(message: "无法解析 \(url.path)（可能含有注释），为避免破坏它，请手动添加：\n\(manualConfiguration)")
            }
            root = parsed
            try backUp(url)
        } else if !enabled {
            return
        }
        var servers = root[key] as? [String: Any] ?? [:]
        if enabled {
            servers[Self.serverName] = switch style {
            case .standard: ["command": cliPath, "args": ["mcp"]] as [String: Any]
            case .vscode: ["type": "stdio", "command": cliPath, "args": ["mcp"]]
            case .opencode: ["type": "local", "command": [cliPath, "mcp"], "enabled": true]
            }
        } else {
            servers[Self.serverName] = nil
        }
        root[key] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Keeps the user's original file once, before Folio first changes it.
    private func backUp(_ url: URL) throws {
        let backup = url.appendingPathExtension("folio-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }
    }

    // MARK: Codex TOML

    private var codexConfig: URL { home.appending(path: ".codex/config.toml") }
    private static let codexHeader = "[mcp_servers.\(serverName)]"

    func codexCommand() -> String? {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.codexHeader }) else { return nil }
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            if trimmed.hasPrefix("command") , let quote = trimmed.firstIndex(of: "\"") {
                let rest = trimmed[trimmed.index(after: quote)...]
                return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
            }
        }
        return ""
    }

    func editCodexTOML(enabled: Bool) throws {
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if !text.isEmpty { try backUp(codexConfig) }
        var lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == Self.codexHeader }) {
            var end = start + 1
            while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            // Also drop a sub-table such as [mcp_servers.folio.env].
            while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[mcp_servers.\(Self.serverName).") {
                end += 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            }
            lines.removeSubrange(start..<end)
        }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if enabled {
            let escaped = cliPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            text += (text.isEmpty ? "" : "\n\n") + "\(Self.codexHeader)\ncommand = \"\(escaped)\"\nargs = [\"mcp\"]"
        }
        try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (text + "\n").write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    // MARK: Skills

    private func skillFile(_ descriptor: AgentDescriptor) -> URL? {
        descriptor.skillsFolder.map { home.appending(path: "\($0)/\(FolioSkill.name)/SKILL.md") }
    }

    func skillInstalled(_ descriptor: AgentDescriptor) -> Bool {
        guard let file = skillFile(descriptor), let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains(FolioSkill.marker)
    }

    public func setSkill(_ enabled: Bool, for descriptor: AgentDescriptor) throws {
        guard let file = skillFile(descriptor) else {
            throw AgentIntegrationError(message: descriptor.skillNote ?? "\(descriptor.name) 不支持技能。")
        }
        let folder = file.deletingLastPathComponent()
        if enabled {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FolioSkill.markdown(cliPath: cliPath).write(to: file, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: file.path) {
            // Only remove a folder Folio wrote; never the user's own skill of the same name.
            guard skillInstalled(descriptor) else {
                throw AgentIntegrationError(message: "\(folder.path) 不是 Folio 安装的技能，未删除。")
            }
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Writes the skill folder (for agents configured by hand or uploaded as a package).
    public func exportSkill(to folder: URL) throws -> URL {
        let target = folder.appending(path: FolioSkill.name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FolioSkill.markdown(cliPath: cliPath).write(to: target.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        return target
    }

    /// Refreshes skills Folio installed earlier (new skill text, moved app).
    @discardableResult
    public func refreshInstalledSkills() -> Int {
        Self.catalog.filter(skillInstalled).reduce(0) { count, descriptor in
            (try? setSkill(true, for: descriptor)) == nil ? count : count + 1
        }
    }
}
