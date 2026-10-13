import Foundation
import Testing
@testable import FolioAgent

private let cli = "/Applications/Folio.app/Contents/MacOS/folio-cli"

private func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "folio-home-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func integrator(_ home: URL) -> AgentIntegrator {
    var integrator = AgentIntegrator(home: home, cliPath: cli, useAgentCommands: false)
    integrator.applicationFolders = []
    return integrator
}

private func descriptor(_ id: String) -> AgentDescriptor { AgentIntegrator.catalog.first { $0.id == id }! }

private func write(_ text: String, to path: String, in home: URL) throws {
    let url = home.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func read(_ path: String, in home: URL) throws -> String {
    try String(contentsOf: home.appending(path: path), encoding: .utf8)
}

@Suite struct JSONCEditorTests {
    let entry = OrderedJSON.object([("command", .string("/x/folio-cli")), ("args", .array([.string("mcp")]))])

    @Test func insertingKeepsCommentsOrderAndIndentation() throws {
        let original = """
        {
            // my servers
            "zeta": 1,
            "mcpServers": {
                "other": { "command": "x" }, /* keep me */
            },
            "alpha": true,
        }
        """
        var document = JSONCDocument(original)
        try document.setMember("folio", in: "mcpServers", to: entry)
        #expect(document.text.contains("// my servers") && document.text.contains("/* keep me */"))
        #expect(document.text.range(of: "\"zeta\"")!.lowerBound < document.text.range(of: "\"alpha\"")!.lowerBound)
        #expect(document.text.contains("\n        \"folio\": {\n            \"command\": \"/x/folio-cli\",\n            \"args\": [\"mcp\"]\n        }"))
        let servers = try #require(try document.object()["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["other", "folio"])

        try document.setMember("folio", in: "mcpServers", to: nil)
        #expect(document.text == original, "removing restores the file byte for byte")
    }

    @Test func strictJSONStaysStrict() throws {
        let original = "{\n  \"mcpServers\": {\n    \"a\": {\n      \"command\": \"a\"\n    }\n  }\n}\n"
        var document = JSONCDocument(original)
        try document.setMember("folio", in: "mcpServers", to: entry)
        _ = try JSONSerialization.jsonObject(with: Data(document.text.utf8))   // no trailing commas, no comments
        try document.setMember("folio", in: "mcpServers", to: nil)
        #expect(document.text == original)
        // First member removed: its line and comma go.
        var first = JSONCDocument("{\n  \"mcpServers\": {\n    \"folio\": {},\n    \"a\": 1\n  }\n}")
        try first.setMember("folio", in: "mcpServers", to: nil)
        #expect(first.text == "{\n  \"mcpServers\": {\n    \"a\": 1\n  }\n}")
    }

    @Test func missingContainersAndFilesAreCreated() throws {
        var empty = JSONCDocument("")
        try empty.setMember("folio", in: "servers", to: entry)
        #expect((try empty.object()["servers"] as? [String: Any])?["folio"] != nil)
        var noKey = JSONCDocument("{\n\t\"theme\": \"dark\"\n}")
        try noKey.setMember("folio", in: "context_servers", to: entry)
        #expect(noKey.text.hasPrefix("{\n\t\"theme\": \"dark\",\n\t\"context_servers\": {\n\t\t\"folio\": {"))
        var emptyObject = JSONCDocument("{ \"mcpServers\": {} }")
        try emptyObject.setMember("folio", in: "mcpServers", to: entry)
        #expect((try emptyObject.object()["mcpServers"] as? [String: Any])?["folio"] != nil)
        var nullContainer = JSONCDocument("{ \"mcpServers\": null }")
        try nullContainer.setMember("folio", in: "mcpServers", to: entry)
        #expect((try nullContainer.object()["mcpServers"] as? [String: Any])?["folio"] != nil)
        var notJSON = JSONCDocument("{ oops")
        #expect(throws: JSONCError.self) { try notJSON.setMember("folio", in: "mcpServers", to: entry) }
        #expect(notJSON.text == "{ oops")
    }

    @Test func aByteOrderMarkIsKept() throws {
        var document = JSONCDocument("\u{FEFF}{\n  \"mcpServers\": {}\n}\n")
        try document.setMember("folio", in: "mcpServers", to: entry)
        #expect(document.text.hasPrefix("\u{FEFF}{"))
        #expect((try document.object()["mcpServers"] as? [String: Any])?["folio"] != nil)
    }

    @Test func stringsWithSlashesAndBracesAreNotComments() throws {
        var document = JSONCDocument(#"{"url": "http://x/*y*/", "s": "}{", "mcpServers": {"a": "//b"}}"#)
        try document.setMember("folio", in: "mcpServers", to: entry)
        let root = try document.object()
        #expect(root["url"] as? String == "http://x/*y*/" && root["s"] as? String == "}{")
        #expect((root["mcpServers"] as? [String: Any])?["a"] as? String == "//b")
    }
}

@Suite struct AgentCatalogTests {
    @Test func everyAgentFollowsItsOfficialLayout() {
        #expect(descriptor("codex").skillFolders == [".agents/skills"], "Codex reads personal skills from ~/.agents/skills only")
        #expect(descriptor("claude-code").skillFolders == [".claude/skills"])
        #expect(descriptor("vscode").skillFolders.contains(".agents/skills"))
        #expect(descriptor("cursor").skillFolders.contains(".agents/skills"))
        #expect(descriptor("kiro").skillFolders == [".kiro/skills"])
        #expect(descriptor("cline").skillFolders == [".cline/skills"])
        #expect(descriptor("antigravity").skillFolders.first == ".gemini/config/skills")
        #expect(Set(AgentIntegrator.catalog.map(\.id)).count == AgentIntegrator.catalog.count)
        #expect(AgentIntegrator.catalog.contains { $0.id == "zed" } && AgentIntegrator.catalog.contains { $0.id == "copilot-cli" })
    }

    @Test func entryStylesMatchEachAgentsSchema() throws {
        let home = try tempHome()
        let agent = integrator(home)
        for id in ["copilot-cli", "zed", "claude-code", "qwen-code", "kiro"] { try agent.setMCP(true, for: descriptor(id)) }
        let copilot = try JSONCDocument(read(".copilot/mcp-config.json", in: home)).object()
        let copilotEntry = try #require((copilot["mcpServers"] as? [String: Any])?["folio"] as? [String: Any])
        #expect(copilotEntry["type"] as? String == "local" && copilotEntry["tools"] as? [String] == ["*"])
        let zed = try JSONCDocument(read(".config/zed/settings.json", in: home)).object()
        #expect(((zed["context_servers"] as? [String: Any])?["folio"] as? [String: Any])?["command"] as? String == cli)
        let claude = try JSONCDocument(read(".claude.json", in: home)).object()
        #expect(((claude["mcpServers"] as? [String: Any])?["folio"] as? [String: Any])?["type"] as? String == "stdio")
        for id in ["copilot-cli", "zed", "claude-code", "qwen-code", "kiro"] {
            #expect(agent.status(of: descriptor(id)).mcpInstalled, "\(id)")
            try agent.setMCP(false, for: descriptor(id))
            #expect(!agent.status(of: descriptor(id)).mcpInstalled, "\(id)")
        }
    }

    @Test func zedSettingsWithCommentsAreEditedInPlace() throws {
        let home = try tempHome()
        let settings = "// Zed settings\n{\n  \"theme\": \"One Dark\", // favourite\n  \"vim_mode\": true,\n}\n"
        try write(settings, to: ".config/zed/settings.json", in: home)
        try integrator(home).setMCP(true, for: descriptor("zed"))
        let edited = try read(".config/zed/settings.json", in: home)
        #expect(edited.hasPrefix("// Zed settings\n{\n  \"theme\": \"One Dark\", // favourite\n  \"vim_mode\": true,\n  \"context_servers\""))
        try integrator(home).setMCP(false, for: descriptor("zed"))
        #expect(try read(".config/zed/settings.json", in: home).contains("\"context_servers\": {"), "an empty container may stay")
        #expect(try read(".config/zed/settings.json", in: home).contains("// favourite"))
    }

    @Test func movedConfigurationFoldersAreFollowed() throws {
        let home = try tempHome()
        // Windsurf before the Devin rename: only ~/.codeium/windsurf exists.
        try FileManager.default.createDirectory(at: home.appending(path: ".codeium/windsurf"), withIntermediateDirectories: true)
        try integrator(home).setMCP(true, for: descriptor("windsurf"))
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".codeium/windsurf/mcp_config.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".config/devin/mcp_config.json").path))
        // Cline: both the VS Code extension and the CLI get the server.
        for folder in ["Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings", ".cline/data/settings"] {
            try FileManager.default.createDirectory(at: home.appending(path: folder), withIntermediateDirectories: true)
        }
        try integrator(home).setMCP(true, for: descriptor("cline"))
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".cline/data/settings/cline_mcp_settings.json").path))
        #expect(FileManager.default.fileExists(atPath: home.appending(
            path: "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json").path))
        // opencode: an existing opencode.jsonc is the configuration, not a new opencode.json.
        try write("{\n  // mine\n  \"$schema\": \"https://opencode.ai/config.json\"\n}\n", to: ".config/opencode/opencode.jsonc", in: home)
        try integrator(home).setMCP(true, for: descriptor("opencode"))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".config/opencode/opencode.json").path))
        #expect(try read(".config/opencode/opencode.jsonc", in: home).contains("// mine"))
        #expect(integrator(home).status(of: descriptor("opencode")).mcpConfigPath == "~/.config/opencode/opencode.jsonc")
    }

    @Test func codexSkillGoesWhereCodexReadsIt() throws {
        let home = try tempHome()
        let agent = integrator(home)
        try agent.setSkill(true, for: descriptor("codex"))
        let skill = home.appending(path: ".agents/skills/folio-library")
        #expect(FileManager.default.fileExists(atPath: skill.appending(path: "SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: skill.appending(path: "references/tools.md").path))
        // Shared folder: Gemini CLI, Cursor, VS Code … see the same copy.
        for id in ["gemini-cli", "cursor", "vscode", "copilot-cli", "windsurf", "opencode", "zed"] {
            #expect(agent.status(of: descriptor(id)).skillInstalled, "\(id)")
        }
        #expect(!agent.status(of: descriptor("claude-code")).skillInstalled)
        // Turning it on for Cursor adds no second copy.
        try agent.setSkill(true, for: descriptor("cursor"))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".cursor/skills/folio-library").path))
        let losing = agent.agentsLosingSkill(ifRemovedFor: descriptor("codex")).map(\.id)
        #expect(losing.contains("gemini-cli") && losing.contains("cursor") && !losing.contains("claude-code"))
        // With Claude Code's own copy, Cursor and VS Code keep seeing the skill.
        try agent.setSkill(true, for: descriptor("claude-code"))
        #expect(!agent.agentsLosingSkill(ifRemovedFor: descriptor("codex")).map(\.id).contains("cursor"))
        try agent.setSkill(false, for: descriptor("codex"))
        #expect(!FileManager.default.fileExists(atPath: skill.path))
        #expect(agent.status(of: descriptor("cursor")).skillFolder == ".claude/skills")
    }

    @Test func skillsFromEarlierVersionsMoveWhereAgentsReadThem() throws {
        let home = try tempHome()
        let old = home.appending(path: ".codex/skills/folio-library")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try "---\nname: folio-library\n---\n\(FolioSkill.marker)\nold text \(cli)".write(to: old.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(integrator(home).refreshInstalledSkills() >= 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FolioSkill.isCurrent(at: home.appending(path: ".agents/skills/folio-library"), cliPath: cli))
        #expect(integrator(home).refreshInstalledSkills() == 0, "nothing to do the second time")
        // A user's own skill in the retired folder is left alone.
        let mine = home.appending(path: ".codex/skills/folio-library")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try "my own".write(to: mine.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        _ = integrator(home).refreshInstalledSkills()
        #expect(FileManager.default.fileExists(atPath: mine.path))
    }
}

@Suite struct FolioSkillTests {
    @Test func frontmatterFollowsTheAgentSkillsSpec() throws {
        let text = FolioSkill.markdown(cliPath: cli)
        #expect(text.hasPrefix("---\nname: folio-library\ndescription: "))
        let lines = text.components(separatedBy: "\n")
        let description = String(try #require(lines.first { $0.hasPrefix("description: ") }).dropFirst("description: ".count))
        #expect(description.count <= 1024, "VS Code and the open spec cap descriptions at 1024 characters")
        #expect(!description.contains(": ") && !description.contains(" #"), "a plain YAML scalar")
        #expect(lines.firstIndex(of: "---", after: 0)! < lines.firstIndex(of: FolioSkill.marker)!)
        #expect(lines.count < 200, "SKILL.md stays short; details live in references/")
        #expect(text.contains("allowed-tools: mcp__folio__search_library"))
        #expect(!text.contains("mcp__folio__move_to_trash"))
    }

    @Test func referencesCoverEveryToolAndLink() throws {
        let files = Dictionary(uniqueKeysWithValues: FolioSkill.files(cliPath: "/Apps/Folio Beta.app/Contents/MacOS/folio-cli").map { ($0.path, $0.contents) })
        let tools = try #require(files["references/tools.md"])
        for tool in ToolCatalog.all { #expect(tools.contains("## `\(tool.name)`"), "\(tool.name)") }
        #expect(tools.contains("`item` (string, required)"))
        let skill = try #require(files["SKILL.md"])
        for link in ["references/tools.md", "references/cli.md", "references/writing.md"] {
            #expect(skill.contains("](\(link))") && files[link] != nil)
        }
        #expect(try #require(files["references/cli.md"]).contains("\"/Apps/Folio Beta.app/Contents/MacOS/folio-cli\" status"), "paths with spaces are quoted")
        #expect(try #require(files["references/writing.md"]).contains("\\cite{key}"))
    }
}

private extension Array where Element == String {
    func firstIndex(of value: String, after index: Int) -> Int? {
        self[(index + 1)...].firstIndex(of: value)
    }
}
