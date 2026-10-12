import FolioCore
import Foundation
import Testing
@testable import FolioAgent

private func makeToolbox(allowWrites: Bool = true) throws -> (LibraryToolbox, Library) {
    let library = try Library.temporary()
    let toolbox = LibraryToolbox(library: library, configuration: AgentConfiguration(libraryRoot: library.root, allowWrites: allowWrites))
    return (toolbox, library)
}

private func seed(_ library: Library) throws -> [String] {
    var ids: [String] = []
    for (title, family, year, doi) in [("Serp-Mamba: Retinal Vessel Segmentation with State Space Models", "Wang", 2025, "10.1/serp"),
                                       ("Night-Time Scene Parsing With a Large Real Dataset", "Tan", 2021, "10.1/night"),
                                       ("A Survey of Vessel Segmentation", "Li", 2023, nil)] {
        var m = Metadata(title: title)
        m.authors = [Author(family: family, given: "X")]
        m.year = year
        m.doi = doi
        m.source = "Journal"
        guard case .created(let id) = try library.createItem(m) else { throw ToolError("seed") }
        ids.append(id)
    }
    return ids
}

@Suite struct LibraryToolboxTests {
    @Test func searchRanksByMatchedWords() async throws {
        let (toolbox, library) = try makeToolbox()
        let ids = try seed(library)
        let result = try await toolbox.call("search_library", arguments: ["query": "mamba retinal vessel"])
        let results = result["results"]?.arrayValue ?? []
        #expect(results.first?["id"]?.stringValue == ids[0])
        #expect(results.first?["matched"]?.intValue == 3)
        #expect(results.count == 2, "the survey matches 'vessel' only; night-time matches nothing")
    }

    @Test func itemsResolveByIdDOIAndKey() async throws {
        let (toolbox, library) = try makeToolbox()
        let ids = try seed(library)
        let byDOI = try await toolbox.call("get_item", arguments: ["item": "https://doi.org/10.1/night"])
        #expect(byDOI["id"]?.stringValue == ids[1])
        let key = try library.item(ids[1])!.citationKey!
        let byKey = try await toolbox.call("get_item", arguments: ["item": .string(key)])
        #expect(byKey["id"]?.stringValue == ids[1])
        await #expect(throws: ToolError.self) { try await toolbox.call("get_item", arguments: ["item": "nope"]) }
    }

    @Test func organiseExportAndTrash() async throws {
        let (toolbox, library) = try makeToolbox()
        let ids = try seed(library)
        _ = try await toolbox.call("set_tags", arguments: ["items": [.string(ids[0])], "add": ["必读"]])
        _ = try await toolbox.call("set_groups", arguments: ["items": [.string(ids[0]), .string(ids[2])], "add": ["医学/血管"]])
        let s = try library.snapshot()
        let child = try #require(s.groupsById.values.first { $0.name == "血管" })
        #expect(s.groupsById[child.parentId!]?.name == "医学")
        #expect(s.groupItems[child.id] == [ids[0], ids[2]])
        let ris = try await toolbox.call("export_references", arguments: ["collection": "group:医学", "format": "ris"])
        #expect(ris["count"]?.intValue == 2)
        let apa = try await toolbox.call("format_citations", arguments: ["items": [.string(ids[1])], "style": "apa"])
        #expect(apa["text"]?.stringValue?.contains("Night-Time Scene Parsing") == true)
        _ = try await toolbox.call("move_to_trash", arguments: ["items": [.string(ids[2])]])
        #expect(try library.item(ids[2])?.isTrashed == true)
        _ = try await toolbox.call("restore_from_trash", arguments: ["items": [.string(ids[2])]])
        #expect(try library.item(ids[2])?.isTrashed == false)
    }

    @Test func importAndNotes() async throws {
        let (toolbox, library) = try makeToolbox()
        let result = try await toolbox.call("import_references", arguments: [
            "text": "@article{li2024x, title={Imported Paper}, author={Li, Wei}, year={2024}}", "group": "导入"])
        #expect(result["created"]?.intValue == 1)
        _ = try await toolbox.call("set_note", arguments: ["item": "li2024x", "content": "第一行"])
        let note = try await toolbox.call("set_note", arguments: ["item": "li2024x", "content": "第二行"])
        #expect(note["note"]?.stringValue == "第一行\n\n第二行")
        #expect(try library.snapshot().notedItems.count == 1)
    }

    @Test func readOnlyModeHidesAndRefusesWrites() async throws {
        let (toolbox, library) = try makeToolbox(allowWrites: false)
        let ids = try seed(library)
        #expect(await toolbox.tools.allSatisfy { !$0.writes })
        await #expect(throws: ToolError.self) {
            try await toolbox.call("move_to_trash", arguments: ["items": [.string(ids[0])]])
        }
        #expect(try library.item(ids[0])?.isTrashed == false)
    }
}

@Suite struct MCPServerTests {
    @Test func handshakeListAndCall() async throws {
        let (toolbox, library) = try makeToolbox()
        _ = try seed(library)
        let server = MCPServer(toolbox: toolbox)
        let initialize = try JSONValue.decode(await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)!)
        #expect(initialize["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let list = try JSONValue.decode(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!)
        #expect(list["result"]?["tools"]?.arrayValue?.count == ToolCatalog.all.count)
        let call = try JSONValue.decode(await server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_library","arguments":{"query":"night"}}}"#)!)
        #expect(call["result"]?["isError"] == false)
        #expect(call["result"]?["structuredContent"]?["total_matches"]?.intValue == 1)
        let failure = try JSONValue.decode(await server.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_item","arguments":{"item":"x"}}}"#)!)
        #expect(failure["result"]?["isError"] == true)
        let unknown = try JSONValue.decode(await server.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"nope"}"#)!)
        #expect(unknown["error"]?["code"]?.intValue == -32601)
        let garbage = try JSONValue.decode(await server.handle(line: "not json")!)
        #expect(garbage["error"]?["code"]?.intValue == -32700)
    }
}

@Suite struct AgentIntegratorTests {
    func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func integrator(_ home: URL, cli: String = "/Applications/Folio.app/Contents/MacOS/folio-cli") -> AgentIntegrator {
        var integrator = AgentIntegrator(home: home, cliPath: cli, useAgentCommands: false)
        integrator.applicationFolders = []
        return integrator
    }

    func descriptor(_ id: String) -> AgentDescriptor { AgentIntegrator.catalog.first { $0.id == id }! }

    @Test func detectsByMarkersOnly() throws {
        let home = try tempHome()
        try FileManager.default.createDirectory(at: home.appending(path: ".cursor"), withIntermediateDirectories: true)
        let statuses = integrator(home).detect()
        let cursor = statuses.first { $0.id == "cursor" }!
        #expect(cursor.isDetected && cursor.location == "~/.cursor")
        #expect(!(statuses.first { $0.id == "windsurf" }!.isDetected))
    }

    @Test func jsonConfigKeepsOtherServersAndBacksUp() throws {
        let home = try tempHome()
        let file = home.appending(path: ".cursor/mcp.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers": {"other": {"command": "x"}}, "keep": 1}"#.write(to: file, atomically: true, encoding: .utf8)
        let agent = integrator(home)
        try agent.setMCP(true, for: descriptor("cursor"))
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let servers = root["mcpServers"] as! [String: Any]
        #expect(servers["other"] != nil && root["keep"] as? Int == 1)
        #expect((servers["folio"] as? [String: Any])?["args"] as? [String] == ["mcp"])
        #expect(FileManager.default.fileExists(atPath: file.path + ".folio-backup"))
        #expect(agent.status(of: descriptor("cursor")).mcpInstalled)
        try agent.setMCP(false, for: descriptor("cursor"))
        root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        #expect((root["mcpServers"] as! [String: Any]).keys.sorted() == ["other"])
    }

    @Test func vscodeAndOpencodeStyles() throws {
        let home = try tempHome()
        let agent = integrator(home)
        try agent.setMCP(true, for: descriptor("vscode"))
        try agent.setMCP(true, for: descriptor("opencode"))
        let vscode = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: "Library/Application Support/Code/User/mcp.json"))) as! [String: Any]
        #expect(((vscode["servers"] as! [String: Any])["folio"] as! [String: Any])["type"] as? String == "stdio")
        let opencode = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appending(path: ".config/opencode/opencode.json"))) as! [String: Any]
        #expect(((opencode["mcp"] as! [String: Any])["folio"] as! [String: Any])["command"] as? [String]
                == ["/Applications/Folio.app/Contents/MacOS/folio-cli", "mcp"])
    }

    @Test func unparsableJSONIsNotOverwritten() throws {
        let home = try tempHome()
        let file = home.appending(path: ".gemini/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ // comment\n \"a\": 1 }".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: AgentIntegrationError.self) { try integrator(home).setMCP(true, for: descriptor("gemini-cli")) }
        #expect(try String(contentsOf: file, encoding: .utf8).contains("// comment"))
    }

    @Test func codexTOMLBlockIsAddedReplacedAndRemoved() throws {
        let home = try tempHome()
        let file = home.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"x\"\n".write(to: file, atomically: true, encoding: .utf8)
        try integrator(home, cli: "/old/folio-cli").setMCP(true, for: descriptor("codex"))
        #expect(integrator(home).status(of: descriptor("codex")).mcpNeedsUpdate)
        #expect(integrator(home).repairMovedPaths() == ["Codex"])
        var text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.components(separatedBy: "[mcp_servers.folio]").count == 2, "one block, not two")
        #expect(text.contains("command = \"/Applications/Folio.app/Contents/MacOS/folio-cli\""))
        #expect(text.contains("[mcp_servers.other]") && text.hasPrefix("model = \"gpt-5\""))
        try integrator(home).setMCP(false, for: descriptor("codex"))
        text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("folio") && text.contains("[mcp_servers.other]"))
    }

    @Test func claudeCodeFallsBackToItsJSON() throws {
        let home = try tempHome()
        try #"{"projects": {}, "mcpServers": {}}"#.write(to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        let agent = integrator(home)
        try agent.setMCP(true, for: descriptor("claude-code"))
        #expect(agent.status(of: descriptor("claude-code")).mcpInstalled)
    }

    @Test func skillsAreInstalledAndOnlyOursRemoved() throws {
        let home = try tempHome()
        let agent = integrator(home)
        try agent.setSkill(true, for: descriptor("claude-code"))
        let skill = home.appending(path: ".claude/skills/folio-library/SKILL.md")
        let text = try String(contentsOf: skill, encoding: .utf8)
        #expect(text.hasPrefix("---\nname: folio-library\n"))
        #expect(text.contains("/Applications/Folio.app/Contents/MacOS/folio-cli call"))
        #expect(agent.status(of: descriptor("claude-code")).skillInstalled)
        try agent.setSkill(false, for: descriptor("claude-code"))
        #expect(!FileManager.default.fileExists(atPath: skill.path))
        // A user's own skill with the same name is left alone.
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "my own".write(to: skill, atomically: true, encoding: .utf8)
        #expect(throws: AgentIntegrationError.self) { try agent.setSkill(false, for: descriptor("claude-code")) }
        #expect(throws: AgentIntegrationError.self) { try agent.setSkill(true, for: descriptor("vscode")) }
    }
}
