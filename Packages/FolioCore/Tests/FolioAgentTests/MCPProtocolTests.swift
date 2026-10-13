import FolioCore
import Foundation
import Testing
@testable import FolioAgent

/// Thread-safe box for a configuration a test changes while the server runs.
private final class ConfigurationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AgentConfiguration
    init(_ value: AgentConfiguration) { self.value = value }
    func get() -> AgentConfiguration { lock.withLock { value } }
    func set(_ change: (inout AgentConfiguration) -> Void) { lock.withLock { change(&value) } }
}

private func decode(_ line: String?) throws -> JSONValue { try JSONValue.decode(try #require(line)) }

@Suite struct MCPProtocolTests {
    func server(allowWrites: Bool = true) throws -> (MCPServer, Library) {
        let library = try Library.temporary()
        let toolbox = LibraryToolbox(library: library, configuration: AgentConfiguration(libraryRoot: library.root, allowWrites: allowWrites))
        return (MCPServer(toolbox: toolbox), library)
    }

    @Test func stdinIsSplitOnLineFeedsOnly() async throws {
        let pipe = Pipe()
        // A raw U+2028 inside a JSON string (as Node's JSON.stringify sends it), a CRLF line and a final
        // line without a newline: three messages, none split.
        let text = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":{\"q\":\"a\u{2028}b\u{2029}c\u{85}d\"}}\n"
            + "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\r\n\n"
            + "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}"
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        var messages: [JSONValue] = []
        for await data in StdioTransport.messages(from: pipe.fileHandleForReading) { messages.append(try JSONValue.decode(data)) }
        #expect(messages.map { $0["id"]?.intValue } == [1, 2, 3])
        #expect(messages[0]["params"]?["q"]?.stringValue == "a\u{2028}b\u{2029}c\u{85}d")
    }

    @Test func outputEscapesLineSeparators() throws {
        let line = JSONValue.object(["text": .string("a\u{2028}b\u{2029}c")]).wireLine
        #expect(!line.contains("\u{2028}") && !line.contains("\u{2029}"))
        #expect(try JSONValue.decode(line)["text"]?.stringValue == "a\u{2028}b\u{2029}c")
    }

    @Test func responsesGoThroughTheTransportAsLines() async throws {
        let (server, _) = try server()
        let pipe = Pipe()
        let transport = StdioTransport(output: pipe.fileHandleForWriting)
        await server.receive(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"search_library","arguments":{"query":"x y"}}}"#.utf8),
                             transport: transport)
        await server.receive(Data("garbage".utf8), transport: transport)
        try pipe.fileHandleForWriting.close()
        let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(try JSONValue.decode(String(lines[0]))["id"]?.intValue == 7)
        #expect(try JSONValue.decode(String(lines[1]))["error"]?["code"]?.intValue == -32700)
    }

    @Test func modernRequestsCarryTheirVersion() async throws {
        let (server, _) = try server()
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        let discover = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{\#(meta)}}"#))
        let result = try #require(discover["result"])
        #expect(result["resultType"]?.stringValue == "complete")
        #expect(result["supportedVersions"]?.stringList.first == "2026-07-28")
        #expect(result["supportedVersions"]?.stringList.contains("2024-11-05") == true)
        #expect(result["capabilities"]?["tools"] != nil && result["capabilities"]?["prompts"] != nil)
        #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.stringValue == "folio")
        #expect(result["cacheScope"]?.stringValue == "private" && result["ttlMs"]?.intValue != nil)

        // No initialize needed: tools/list straight away.
        let list = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(meta)}}"#))
        #expect(list["result"]?["tools"]?.arrayValue?.count == ToolCatalog.all.count)
        #expect(list["result"]?["resultType"]?.stringValue == "complete")
        let call = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_collections","arguments":{},\#(meta)}}"#))
        #expect(call["result"]?["isError"] == false && call["result"]?["resultType"]?.stringValue == "complete")

        let future = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2099-01-01"}}}"#))
        #expect(future["error"]?["code"]?.intValue == -32022)
        #expect(future["error"]?["data"]?["supported"]?.stringList.contains("2026-07-28") == true)
        #expect(future["error"]?["data"]?["requested"]?.stringValue == "2099-01-01")
    }

    @Test func legacyHandshakeNegotiatesTheVersion() async throws {
        let (server, _) = try server()
        for (asked, expected) in [("2025-11-25", "2025-11-25"), ("2024-11-05", "2024-11-05"), ("2030-01-01", "2025-11-25")] {
            let reply = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(asked)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
            #expect(reply["result"]?["protocolVersion"]?.stringValue == expected)
            #expect(reply["result"]?["resultType"] == nil, "legacy results stay as they were")
            #expect(reply["result"]?["capabilities"]?["tools"]?["listChanged"] == true)
        }
        #expect(try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#))["result"] == .object([:]))
    }

    @Test func badArgumentsAreExplainedToTheModel() async throws {
        let (server, _) = try server()
        let reply = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_library","arguments":{"q":"mamba","limit":"many"}}}"#))
        #expect(reply["result"]?["isError"] == true)
        let text = reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("unknown parameter \"q\""))
        #expect(text.contains("\"limit\" must be an integer"))
        #expect(text.contains("Accepted parameters:") && text.contains("query"))
        let missing = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_item","arguments":{}}}"#))
        #expect(missing["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("missing \"item\"") == true)
    }

    @Test func promptsAreListedAndFilledIn() async throws {
        let (server, _) = try server()
        let list = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"prompts/list"}"#))
        #expect(list["result"]?["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["find_paper", "cite_papers", "summarize_paper"])
        let get = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"prompts/get","params":{"name":"cite_papers","arguments":{"papers":"Mamba; Night-time","style":"ieee"}}}"#))
        let text = get["result"]?["messages"]?.arrayValue?.first?["content"]?["text"]?.stringValue ?? ""
        #expect(text.contains("Mamba; Night-time") && text.contains("\"ieee\"") && text.contains("format_citations"))
        let missing = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"prompts/get","params":{"name":"find_paper","arguments":{}}}"#))
        #expect(missing["error"]?["code"]?.intValue == -32602)
    }

    @Test func notificationsAndStrayResponsesGetNoReply() async throws {
        let (server, _) = try server()
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#) == nil)
        #expect(await server.handle(line: #"{"jsonrpc":"2.0","id":5,"result":{}}"#) == nil)
        let batch = try decode(await server.handle(line: #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#))
        #expect(batch.arrayValue?.count == 1)
    }

    @Test func followsTheWritePermissionWhileRunning() async throws {
        let library = try Library.temporary()
        let box = ConfigurationBox(AgentConfiguration(libraryRoot: library.root, allowWrites: true))
        let live = LibraryToolbox(configurationSource: { box.get() })
        await live.refresh()
        #expect(await live.tools.count == ToolCatalog.all.count)
        box.set { $0.allowWrites = false }
        await live.refresh()
        #expect(await live.tools.allSatisfy { !$0.writes })
        await #expect(throws: ToolError.self) { try await live.call("create_tag", arguments: ["name": "x"]) }
    }

    @Test func aMissingLibraryIsExplainedNotFatal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "no-library-\(UUID().uuidString)")
        let server = MCPServer(toolbox: LibraryToolbox(configurationSource: { AgentConfiguration(libraryRoot: root) }))
        let list = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        #expect(list["result"]?["tools"]?.arrayValue?.isEmpty == false)
        let call = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_collections","arguments":{}}}"#))
        #expect(call["result"]?["isError"] == true)
        #expect(call["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("No Folio library at") == true)
        #expect(!FileManager.default.fileExists(atPath: root.path), "the agent never creates a library")
    }

    @Test func prunedDropsEmptyValuesButKeepsTopLevelLists() {
        let value: JSONValue = ["a": .null, "b": "", "c": [], "d": ["e": .null, "f": [], "g": 1], "results": []]
        #expect(value.pruned == ["c": [], "d": ["g": 1], "results": []])
    }
}
