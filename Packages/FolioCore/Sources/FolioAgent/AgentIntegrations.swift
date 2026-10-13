import Foundation

/// An AI agent Folio can configure (AI-04). Paths are relative to the home folder and follow each
/// agent's official documentation (checked 2026-10; see doc/开发计划-v2.6.md §2).
public struct AgentDescriptor: Sendable, Identifiable, Hashable {
    public enum MCPTarget: Sendable, Hashable {
        /// `claude mcp add --scope user` (falls back to `~/.claude.json` → mcpServers).
        case claudeCode
        /// `codex mcp add` (falls back to `~/.codex/config.toml` → [mcp_servers.folio]).
        case codex
        /// A JSON (or JSON-with-comments) file with servers under `key`.
        case json(path: String, key: String, style: EntryStyle)
        /// Several possible files (an agent that moved its configuration, or several editions of it):
        /// Folio reads and removes all of them and writes as `policy` says.
        case jsonAny(paths: [String], key: String, style: EntryStyle, policy: WritePolicy)
    }

    public enum WritePolicy: Sendable, Hashable {
        /// The first file that exists, else the first path (one configuration, several possible names).
        case existingFile
        /// The first path whose folder exists, else the first (an agent that moved its folder).
        case existingFolder
        /// Every path whose folder exists, else the first (separate editions, e.g. extension and CLI).
        case everyExistingFolder
    }

    public enum EntryStyle: Sendable, Hashable {
        /// `{"command": …, "args": […]}` (Claude Desktop, Cursor, Gemini, Windsurf, Cline, LM Studio, Kiro, Antigravity, Qwen).
        case standard
        /// Claude Code's own entries: `{"type": "stdio", "command": …, "args": […], "env": {}}`.
        case claudeCode
        /// VS Code: `{"type": "stdio", "command": …, "args": […]}`.
        case vscode
        /// opencode: `{"type": "local", "command": [cli, "mcp"], "enabled": true}`.
        case opencode
        /// GitHub Copilot CLI: `{"type": "local", "command": …, "args": […], "env": {}, "tools": ["*"]}`.
        case copilotCLI
        /// Zed `context_servers`: `{"command": …, "args": […], "env": {}}`.
        case zed
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
    /// Personal skills folders the agent reads (`<folder>/folio-library/SKILL.md`), preferred first.
    /// Folio installs into the first one whose parent folder exists (else the first).
    public let skillFolders: [String]
    /// Why the skill switch is unavailable, or how to add the skill by hand.
    public let skillNote: String?

    public var supportsSkills: Bool { !skillFolders.isEmpty }
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
    /// The configuration file holding Folio's MCP entry (or where it would go).
    public let mcpConfigPath: String?
    /// The skills folder (relative to home) where the agent finds Folio's skill, when installed.
    public let skillFolder: String?
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

    /// The open Agent Skills standard's shared personal folder (Codex, Gemini CLI, Cursor, VS Code,
    /// Copilot CLI, Windsurf, opencode, Zed read it).
    public static let sharedSkillsFolder = ".agents/skills"

    private static let vscodeUser = "Library/Application Support/Code/User"

    public static let catalog: [AgentDescriptor] = [
        .init(id: "claude-code", name: "Claude Code", apps: [], commands: ["claude"], markers: [".claude"],
              mcp: .claudeCode, skillFolders: [".claude/skills"], skillNote: nil),
        .init(id: "claude-desktop", name: "Claude 桌面版", apps: ["Claude.app"], commands: [],
              markers: ["Library/Application Support/Claude"],
              mcp: .json(path: "Library/Application Support/Claude/claude_desktop_config.json", key: "mcpServers", style: .standard),
              skillFolders: [], skillNote: "Claude 桌面版的技能需在 设置 ▸ 功能 ▸ 技能 中上传，可用下方\"导出技能包…\"生成。"),
        .init(id: "codex", name: "Codex", apps: ["Codex.app"], commands: ["codex"], markers: [".codex"],
              mcp: .codex, skillFolders: [sharedSkillsFolder], skillNote: nil),
        .init(id: "gemini-cli", name: "Gemini CLI", apps: [], commands: ["gemini"],
              markers: [".gemini/settings.json", ".gemini/oauth_creds.json", ".gemini/skills"],
              mcp: .json(path: ".gemini/settings.json", key: "mcpServers", style: .standard),
              skillFolders: [sharedSkillsFolder, ".gemini/skills"], skillNote: nil),
        .init(id: "cursor", name: "Cursor", apps: ["Cursor.app"], commands: ["cursor", "cursor-agent"], markers: [".cursor"],
              mcp: .json(path: ".cursor/mcp.json", key: "mcpServers", style: .standard),
              skillFolders: [sharedSkillsFolder, ".cursor/skills", ".claude/skills", ".codex/skills"], skillNote: nil),
        .init(id: "vscode", name: "VS Code（Copilot）", apps: ["Visual Studio Code.app"], commands: ["code"],
              markers: [vscodeUser],
              mcp: .json(path: "\(vscodeUser)/mcp.json", key: "servers", style: .vscode),
              skillFolders: [sharedSkillsFolder, ".copilot/skills", ".claude/skills"], skillNote: nil),
        .init(id: "copilot-cli", name: "GitHub Copilot CLI", apps: [], commands: ["copilot"],
              markers: [".copilot/config.json", ".copilot/mcp-config.json"],
              mcp: .json(path: ".copilot/mcp-config.json", key: "mcpServers", style: .copilotCLI),
              skillFolders: [sharedSkillsFolder, ".copilot/skills"], skillNote: nil),
        .init(id: "windsurf", name: "Windsurf（Devin Desktop）", apps: ["Windsurf.app", "Devin.app"], commands: ["windsurf", "devin"],
              markers: [".codeium/windsurf", ".config/devin"],
              mcp: .jsonAny(paths: [".config/devin/mcp_config.json", ".codeium/windsurf/mcp_config.json"], key: "mcpServers",
                            style: .standard, policy: .existingFolder),
              skillFolders: [sharedSkillsFolder, ".codeium/windsurf/skills", ".config/devin/skills"], skillNote: nil),
        .init(id: "cline", name: "Cline", apps: [], commands: ["cline"],
              markers: ["\(vscodeUser)/globalStorage/saoudrizwan.claude-dev", ".cline"],
              mcp: .jsonAny(paths: ["\(vscodeUser)/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
                                    ".cline/data/settings/cline_mcp_settings.json"],
                            key: "mcpServers", style: .standard, policy: .everyExistingFolder),
              skillFolders: [".cline/skills"], skillNote: nil),
        .init(id: "opencode", name: "opencode", apps: [], commands: ["opencode"], markers: [".config/opencode"],
              mcp: .jsonAny(paths: [".config/opencode/opencode.json", ".config/opencode/opencode.jsonc"], key: "mcp",
                            style: .opencode, policy: .existingFile),
              skillFolders: [sharedSkillsFolder, ".config/opencode/skills", ".claude/skills"], skillNote: nil),
        .init(id: "antigravity", name: "Antigravity", apps: ["Antigravity.app"], commands: ["antigravity", "agy"],
              markers: [".gemini/config", ".gemini/antigravity", ".gemini/antigravity-cli"],
              mcp: .jsonAny(paths: [".gemini/config/mcp_config.json", ".gemini/antigravity/mcp_config.json"], key: "mcpServers",
                            style: .standard, policy: .existingFolder),
              skillFolders: [".gemini/config/skills", ".gemini/antigravity/skills", ".gemini/antigravity-cli/skills"], skillNote: nil),
        .init(id: "kiro", name: "Kiro", apps: ["Kiro.app"], commands: ["kiro", "kiro-cli"], markers: [".kiro"],
              mcp: .json(path: ".kiro/settings/mcp.json", key: "mcpServers", style: .standard),
              skillFolders: [".kiro/skills"], skillNote: nil),
        .init(id: "zed", name: "Zed", apps: ["Zed.app"], commands: ["zed"], markers: [".config/zed"],
              mcp: .json(path: ".config/zed/settings.json", key: "context_servers", style: .zed),
              skillFolders: [sharedSkillsFolder], skillNote: nil),
        .init(id: "qwen-code", name: "Qwen Code", apps: [], commands: ["qwen"], markers: [".qwen"],
              mcp: .json(path: ".qwen/settings.json", key: "mcpServers", style: .standard),
              skillFolders: [".qwen/skills"], skillNote: nil),
        .init(id: "lm-studio", name: "LM Studio", apps: ["LM Studio.app"], commands: ["lms"], markers: [".lmstudio"],
              mcp: .json(path: ".lmstudio/mcp.json", key: "mcpServers", style: .standard),
              skillFolders: [], skillNote: "LM Studio 不支持技能，可通过 MCP 使用 Folio。"),
    ]

    /// Folders where earlier Folio versions installed the skill but the agent no longer reads it
    /// (Codex moved to ~/.agents/skills): copies there are moved on launch.
    static let retiredSkillFolders = [".codex/skills"]

    // MARK: Detection

    public func detect() -> [AgentStatus] {
        Self.catalog.map(status)
    }

    public func status(of descriptor: AgentDescriptor) -> AgentStatus {
        let location = locate(descriptor)
        let entry = installedCommand(descriptor)
        // Only a configured folio-cli that no longer exists needs re-pointing: another copy of Folio
        // (e.g. a development build) must not take over the user's agents just by launching.
        let stale = entry.map { $0 != cliPath && !FileManager.default.isExecutableFile(atPath: $0) } ?? false
        let skillFolder = descriptor.skillFolders.first { isOurs(skillFile(in: $0)) }
        return AgentStatus(descriptor: descriptor, isDetected: location != nil, location: location,
                           mcpInstalled: entry != nil, skillInstalled: skillFolder != nil,
                           mcpNeedsUpdate: stale, mcpConfigPath: configPath(descriptor), skillFolder: skillFolder)
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
         home.appending(path: ".cargo/bin").path, home.appending(path: ".claude/local").path,
         home.appending(path: ".opencode/bin").path]
    }

    static func findCommand(_ name: String, home: URL) -> String? {
        searchPath(home: home).map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: MCP

    /// The configuration file Folio edits (or the agent's CLI edits) for this agent, for display.
    func configPath(_ descriptor: AgentDescriptor) -> String? {
        switch descriptor.mcp {
        case nil: nil
        case .claudeCode: "~/.claude.json"
        case .codex: "~/.codex/config.toml"
        case let .json(path, _, _): "~/" + path
        case let .jsonAny(paths, key, style, policy):
            paths.first { command(inJSON: $0, key: key, style: style) != nil }.map { "~/" + $0 }
                ?? targets(paths, policy).first.map { "~/" + $0 }
        }
    }

    /// The folio-cli path currently configured for the agent, or nil when Folio's server is absent.
    func installedCommand(_ descriptor: AgentDescriptor) -> String? {
        switch descriptor.mcp {
        case nil:
            return nil
        case .claudeCode:
            return command(inJSON: ".claude.json", key: "mcpServers", style: .claudeCode)
        case .codex:
            return codexCommand()
        case let .json(path, key, style):
            return command(inJSON: path, key: key, style: style)
        case let .jsonAny(paths, key, style, _):
            return paths.lazy.compactMap { command(inJSON: $0, key: key, style: style) }.first
        }
    }

    public func setMCP(_ enabled: Bool, for descriptor: AgentDescriptor) throws {
        switch descriptor.mcp {
        case nil:
            throw AgentIntegrationError(message: "\(descriptor.name) 不支持 MCP。")
        case .claudeCode:
            // The official way: Claude Code's own CLI writes its user-scope configuration.
            if enabled { try? runAgentCommand("claude", ["mcp", "remove", "--scope", "user", Self.serverName]) }
            let args = enabled ? ["mcp", "add", "--scope", "user", Self.serverName, "--", cliPath, "mcp"]
                : ["mcp", "remove", "--scope", "user", Self.serverName]
            if try !runAgentCommand("claude", args) {
                try editJSON(".claude.json", key: "mcpServers", style: .claudeCode, enabled: enabled)
            }
        case .codex:
            if enabled { try? runAgentCommand("codex", ["mcp", "remove", Self.serverName]) }
            let args = enabled ? ["mcp", "add", Self.serverName, "--", cliPath, "mcp"] : ["mcp", "remove", Self.serverName]
            if try !runAgentCommand("codex", args) {
                try editCodexTOML(enabled: enabled)
            }
        case let .json(path, key, style):
            try editJSON(path, key: key, style: style, enabled: enabled)
        case let .jsonAny(paths, key, style, policy):
            if enabled {
                for path in targets(paths, policy) { try editJSON(path, key: key, style: style, enabled: true) }
            } else {
                for path in paths where FileManager.default.fileExists(atPath: home.appending(path: path).path) {
                    try editJSON(path, key: key, style: style, enabled: false)
                }
            }
        }
        // Trust but verify: the agent's own tool may have written somewhere else.
        if (installedCommand(descriptor) != nil) != enabled {
            throw AgentIntegrationError(message: "未能\(enabled ? "添加" : "移除") \(descriptor.name) 的配置，请检查 \(configPath(descriptor) ?? "其配置文件")。")
        }
    }

    /// Which of several candidate files Folio writes.
    private func targets(_ paths: [String], _ policy: AgentDescriptor.WritePolicy) -> [String] {
        let manager = FileManager.default
        let folderExists = { (path: String) in manager.fileExists(atPath: home.appending(path: path).deletingLastPathComponent().path) }
        switch policy {
        case .existingFile:
            return [paths.first { manager.fileExists(atPath: home.appending(path: $0).path) } ?? paths[0]]
        case .existingFolder:
            return [paths.first(where: folderExists) ?? paths[0]]
        case .everyExistingFolder:
            let existing = paths.filter(folderExists)
            return existing.isEmpty ? [paths[0]] : existing
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
        OrderedJSON.object([("mcpServers", .object([(Self.serverName, entry(.standard))]))]).render(indent: "", unit: "  ")
    }

    func entry(_ style: AgentDescriptor.EntryStyle) -> OrderedJSON {
        let args = OrderedJSON.array([.string("mcp")])
        return switch style {
        case .standard: .object([("command", .string(cliPath)), ("args", args)])
        case .claudeCode: .object([("type", .string("stdio")), ("command", .string(cliPath)), ("args", args), ("env", .object([]))])
        case .vscode: .object([("type", .string("stdio")), ("command", .string(cliPath)), ("args", args)])
        case .opencode: .object([("type", .string("local")), ("command", .array([.string(cliPath), .string("mcp")])), ("enabled", .bool(true))])
        case .copilotCLI: .object([("type", .string("local")), ("command", .string(cliPath)), ("args", args), ("env", .object([])),
                                   ("tools", .array([.string("*")]))])
        case .zed: .object([("command", .string(cliPath)), ("args", args), ("env", .object([]))])
        }
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
        process.standardInput = FileHandle.nullDevice
        // A file rather than a pipe: a chatty CLI can never block on a full pipe buffer.
        let log = FileManager.default.temporaryDirectory.appending(path: "folio-agent-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Never hang the settings window on a CLI that waits for something.
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw AgentIntegrationError(message: "\(name) \(arguments.prefix(2).joined(separator: " ")) 没有在 30 秒内完成。")
        }
        if process.terminationStatus != 0 {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
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
              let root = try? JSONCDocument(String(decoding: data, as: UTF8.self)).object(),
              let servers = root[key] as? [String: Any], let entry = servers[Self.serverName] as? [String: Any] else { return nil }
        if style == .opencode { return (entry["command"] as? [String])?.first }
        return entry["command"] as? String
    }

    /// Adds or removes Folio's entry, keeping everything else in the file exactly as it was.
    func editJSON(_ path: String, key: String, style: AgentDescriptor.EntryStyle, enabled: Bool) throws {
        let url = home.appending(path: path)
        let existing = FileManager.default.contents(atPath: url.path).map { String(decoding: $0, as: UTF8.self) }
        guard existing != nil || enabled else { return }
        var document = JSONCDocument(existing ?? "")
        do {
            try document.setMember(Self.serverName, in: key, to: enabled ? entry(style) : nil)
        } catch {
            throw AgentIntegrationError(message: "无法解析 \(url.path)（\(error.localizedDescription)），为避免破坏它，请手动添加：\n\(manualConfiguration)")
        }
        guard document.text != existing else { return }
        if existing != nil { try backUp(url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.text.write(to: url, atomically: true, encoding: .utf8)
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
            if trimmed.hasPrefix("command"), let quote = trimmed.firstIndex(where: { $0 == "\"" || $0 == "'" }) {
                let delimiter = trimmed[quote]
                let rest = trimmed[trimmed.index(after: quote)...]
                return rest.firstIndex(of: delimiter).map { String(rest[..<$0]).replacingOccurrences(of: "\\\\", with: "\\") }
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

    private func skillFile(in folder: String) -> URL {
        home.appending(path: "\(folder)/\(FolioSkill.name)/SKILL.md")
    }

    private func isOurs(_ file: URL) -> Bool {
        (try? String(contentsOf: file, encoding: .utf8))?.contains(FolioSkill.marker) ?? false
    }

    func skillInstalled(_ descriptor: AgentDescriptor) -> Bool {
        descriptor.skillFolders.contains { isOurs(skillFile(in: $0)) }
    }

    /// The folder Folio installs into for this agent: the first whose parent folder exists (the
    /// agent version in use), else the preferred one.
    func skillTarget(_ descriptor: AgentDescriptor) -> String? {
        descriptor.skillFolders.first { FileManager.default.fileExists(atPath: home.appending(path: $0).deletingLastPathComponent().path) }
            ?? descriptor.skillFolders.first
    }

    /// Other agents that would no longer see Folio's skill if it were removed for `descriptor` (they
    /// read it only from folders `descriptor` shares with them).
    public func agentsLosingSkill(ifRemovedFor descriptor: AgentDescriptor) -> [AgentDescriptor] {
        let removed = Set(descriptor.skillFolders.filter { isOurs(skillFile(in: $0)) })
        return Self.catalog.filter { other in
            guard other.id != descriptor.id else { return false }
            let visible = Set(other.skillFolders.filter { isOurs(skillFile(in: $0)) })
            return !visible.isEmpty && visible.isSubset(of: removed)
        }
    }

    public func setSkill(_ enabled: Bool, for descriptor: AgentDescriptor) throws {
        guard let target = skillTarget(descriptor) else {
            throw AgentIntegrationError(message: descriptor.skillNote ?? "\(descriptor.name) 不支持技能。")
        }
        if enabled {
            // Already visible through a folder it shares with another agent: refresh that copy only,
            // so the agent does not see two copies of the same skill.
            let folder = descriptor.skillFolders.first { isOurs(skillFile(in: $0)) } ?? target
            try FolioSkill.write(to: home.appending(path: "\(folder)/\(FolioSkill.name)"), cliPath: cliPath)
        } else {
            for folder in descriptor.skillFolders {
                let file = skillFile(in: folder)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                // Only remove a folder Folio wrote; never the user's own skill of the same name.
                guard isOurs(file) else {
                    if folder == target {
                        throw AgentIntegrationError(message: "\(file.deletingLastPathComponent().path) 不是 Folio 安装的技能，未删除。")
                    }
                    continue
                }
                try FileManager.default.removeItem(at: file.deletingLastPathComponent())
            }
        }
    }

    /// Writes the skill folder (for agents configured by hand or uploaded as a package).
    public func exportSkill(to folder: URL) throws -> URL {
        let target = folder.appending(path: FolioSkill.name, directoryHint: .isDirectory)
        try FolioSkill.write(to: target, cliPath: cliPath)
        return target
    }

    /// Refreshes skills Folio installed earlier: new skill text for this copy of Folio, or a moved app
    /// (the skill names a folio-cli that no longer exists). Skills of another existing copy are left
    /// alone. Copies in folders agents no longer read move to the shared folder. Returns how many
    /// skill folders were rewritten.
    @discardableResult
    public func refreshInstalledSkills() -> Int {
        var count = 0
        for retired in Self.retiredSkillFolders where isOurs(skillFile(in: retired)) {
            let folder = skillFile(in: retired).deletingLastPathComponent()
            if (try? FolioSkill.write(to: home.appending(path: "\(Self.sharedSkillsFolder)/\(FolioSkill.name)"), cliPath: cliPath)) != nil {
                try? FileManager.default.removeItem(at: folder)
                count += 1
            }
        }
        let folders = Set(Self.catalog.flatMap(\.skillFolders)).sorted()
        for folder in folders {
            let file = skillFile(in: folder)
            guard isOurs(file), let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let referenced = text.firstMatch(of: /(\/[^\s"`']*\/folio-cli)/).map { String($0.1) }
            let ours = text.contains(cliPath)
            let orphaned = referenced.map { !FileManager.default.isExecutableFile(atPath: $0) } ?? true
            let target = file.deletingLastPathComponent()
            guard ours || orphaned, !FolioSkill.isCurrent(at: target, cliPath: cliPath) else { continue }
            if (try? FolioSkill.write(to: target, cliPath: cliPath)) != nil { count += 1 }
        }
        return count
    }
}
