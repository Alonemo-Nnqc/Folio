import Foundation

/// A Model Context Protocol server over stdio exposing the library tools and prompts (AI-01).
///
/// Hand-written rather than built on the Swift SDK: Folio only needs the stdio transport, tools and
/// prompts, and the SDK would add swift-nio and several other dependencies.
///
/// Serves both protocol eras on the same process:
/// - **Modern** (2026-07-28): no handshake; every request carries its version in
///   `_meta["io.modelcontextprotocol/protocolVersion"]`; `server/discover` describes the server.
/// - **Legacy** (2025-11-25 and earlier): an `initialize` handshake selects the version.
///
/// Requests run concurrently (a slow PDF lookup never blocks a ping or a cancellation) and can be
/// cancelled with `notifications/cancelled`.
public final class MCPServer: Sendable {
    public static let modernVersions = ["2026-07-28"]
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedProtocolVersions: [String] { modernVersions + legacyVersions }
    public static let serverVersion = "2.6"

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"
    static let serverInfo: JSONValue = ["name": "folio", "title": "Folio 文献库", "version": .string(serverVersion)]

    private let toolbox: LibraryToolbox
    private let state = SessionState()

    public init(toolbox: LibraryToolbox) {
        self.toolbox = toolbox
    }

    /// Serves stdin / stdout until stdin closes.
    public func run(transport: StdioTransport = StdioTransport()) async {
        StdioTransport.log("Folio MCP server \(Self.serverVersion) started")
        let watcher = Task { await watchToolList(transport) }
        await withTaskGroup(of: Void.self) { group in
            for await data in StdioTransport.messages() {
                group.addTask { await self.receive(data, transport: transport) }
            }
        }
        watcher.cancel()
    }

    // MARK: Dispatch

    /// Handles one line and sends its response (if any). Each line runs in its own task.
    func receive(_ data: Data, transport: StdioTransport) async {
        guard let message = try? JSONValue.decode(data) else {
            await transport.send(Self.error(id: .null, code: -32700, message: "Parse error"))
            return
        }
        if case .array(let batch) = message {
            // JSON-RPC batches (2025-03-26 only): answer as one array.
            var responses: [JSONValue] = []
            for entry in batch {
                if let response = await response(to: entry, transport: transport) { responses.append(response) }
            }
            if !responses.isEmpty { await transport.send(.array(responses)) }
            return
        }
        if let response = await response(to: message, transport: transport) {
            await transport.send(response)
        }
    }

    /// Test seam: one line in, the response line (if any) out.
    func handle(line: String) async -> String? {
        guard let message = try? JSONValue.decode(line) else {
            return Self.error(id: .null, code: -32700, message: "Parse error").wireLine
        }
        if case .array(let batch) = message {
            var responses: [JSONValue] = []
            for entry in batch { if let response = await response(to: entry) { responses.append(response) } }
            return responses.isEmpty ? nil : JSONValue.array(responses).wireLine
        }
        return await response(to: message)?.wireLine
    }

    /// The response to one message, or nil for notifications, client responses and cancelled requests.
    func response(to message: JSONValue, transport: StdioTransport? = nil) async -> JSONValue? {
        guard let method = message["method"]?.stringValue else { return nil }   // a response to us: ignore
        let params = message["params"] ?? [:]
        guard let id = message["id"], id != .null else {
            await notification(method, params)
            return nil
        }
        let key = id.encoded()
        let work = Task { await self.handle(method: method, params: params, id: id, transport: transport) }
        await state.started(key, work)
        let response = await work.value
        let wasCancelled = await state.finished(key)
        // A cancelled request gets no further messages (MCP cancellation rules).
        return wasCancelled ? nil : response
    }

    private func notification(_ method: String, _ params: JSONValue) async {
        switch method {
        case "notifications/cancelled":
            if let id = params["requestId"] { await state.cancel(id.encoded()) }
        case "notifications/initialized":
            await state.markInitialized()
        default:
            break
        }
    }

    private func handle(method: String, params: JSONValue, id: JSONValue, transport: StdioTransport?) async -> JSONValue {
        // Modern requests name their version on every call.
        let requested = params["_meta"]?[Self.versionKey]?.stringValue
        let modern = requested != nil
        if let requested, !Self.supportedProtocolVersions.contains(requested) {
            return Self.error(id: id, code: -32022, message: "Unsupported protocol version",
                              data: ["supported": .array(Self.supportedProtocolVersions.map(JSONValue.string)),
                                     "requested": .string(requested)])
        }
        func reply(_ result: [String: JSONValue], cacheable: Bool = false) -> JSONValue {
            var result = result
            if modern {
                result["resultType"] = "complete"
                var meta: [String: JSONValue] = [:]
                if case .object(let existing)? = result["_meta"] { meta = existing }
                meta[Self.serverInfoKey] = Self.serverInfo
                result["_meta"] = .object(meta)
                if cacheable {
                    // The tool list follows 设置 ▸ AI, so clients should not keep it long; it is the
                    // user's own library, never to be shared by intermediaries.
                    result["ttlMs"] = 30_000
                    result["cacheScope"] = "private"
                }
            }
            return ["jsonrpc": "2.0", "id": id, "result": .object(result)]
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.stringValue ?? Self.legacyVersions[0]
            let version = Self.legacyVersions.contains(asked) ? asked : Self.legacyVersions[0]
            await toolbox.refresh()
            await state.startLegacySession(writes: await toolbox.configuration.allowWrites)
            return reply([
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": true], "prompts": ["listChanged": false]],
                "serverInfo": Self.serverInfo,
                "instructions": .string(Self.instructions),
            ])
        case "server/discover":
            return reply([
                "supportedVersions": .array(Self.supportedProtocolVersions.map(JSONValue.string)),
                "capabilities": ["tools": [:], "prompts": [:]],
                "instructions": .string(Self.instructions),
            ], cacheable: true)
        case "ping":
            return reply([:])
        case "logging/setLevel":
            // Folio logs to stderr only; accept the request so older clients do not complain.
            return reply([:])
        case "tools/list":
            await toolbox.refresh()
            let tools = await toolbox.tools.map(\.mcpDescription)
            await state.listedTools(writes: await toolbox.configuration.allowWrites)
            return reply(["tools": .array(tools)], cacheable: true)
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            guard ToolCatalog.tool(named: name) != nil else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name). Call tools/list for the available tools.")
            }
            await toolbox.refresh()
            do {
                let output = try await toolbox.call(name, arguments: params["arguments"] ?? [:])
                if Task.isCancelled { return Self.error(id: id, code: -32800, message: "Request cancelled") }
                return reply(["content": [["type": "text", "text": .string(output.pruned.encoded())]], "isError": false])
            } catch {
                // Tool failures go back to the model (isError) so it can correct itself.
                return reply(["content": [["type": "text", "text": .string(error.localizedDescription)]], "isError": true])
            }
        case "prompts/list":
            return reply(["prompts": .array(MCPPrompts.all.map(\.listEntry))], cacheable: true)
        case "prompts/get":
            guard let name = params["name"]?.stringValue, let prompt = MCPPrompts.prompt(named: name) else {
                return Self.error(id: id, code: -32602, message: "Unknown prompt: \(params["name"]?.stringValue ?? "")")
            }
            do {
                return reply(try prompt.messages(arguments: params["arguments"] ?? [:]))
            } catch {
                return Self.error(id: id, code: -32602, message: error.localizedDescription)
            }
        case "resources/list":
            return reply(["resources": []], cacheable: true)
        case "resources/templates/list":
            return reply(["resourceTemplates": []], cacheable: true)
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    /// Legacy sessions are told when 设置 ▸ AI ▸ 允许 AI 修改文献库 changes the tool list.
    private func watchToolList(_ transport: StdioTransport) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard await state.isLegacySession else { continue }
            await toolbox.refresh()
            if await state.toolListChanged(writes: await toolbox.configuration.allowWrites) {
                await transport.send(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"])
            }
        }
    }

    static let instructions = """
    Folio is the user's reference manager on macOS (like Zotero): their papers, PDFs, highlights and notes. \
    Everything you say about the user's library must come from these tools — never invent papers or citation details. \
    Find papers with search_library (2–4 distinctive keywords; retry with other words, filters such as author / \
    year_from, or include_fulltext), confirm with get_item, read with read_fulltext (use `query` to jump to the \
    relevant passages) and get_annotations, cite with format_citations (copy the text exactly as returned) and \
    export with export_references. Add or organise papers only when the user asks. Ask before delete_tag, \
    delete_group and move_to_trash. Item references can be ids from results, DOIs or citation keys.
    """

    static func error(id: JSONValue, code: Int, message: String, data: JSONValue? = nil) -> JSONValue {
        var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
        if let data { error["data"] = data }
        return ["jsonrpc": "2.0", "id": id, "error": .object(error)]
    }
}

/// In-flight requests and the legacy session's state.
private actor SessionState {
    private var running: [String: Task<JSONValue, Never>] = [:]
    private var cancelled: Set<String> = []
    private(set) var isLegacySession = false
    private var lastListedWrites: Bool?

    func started(_ key: String, _ task: Task<JSONValue, Never>) {
        running[key] = task
    }

    /// Returns whether the request was cancelled.
    func finished(_ key: String) -> Bool {
        running[key] = nil
        return cancelled.remove(key) != nil
    }

    /// Cancels a running request; ids that are not running (finished, or never seen) are ignored.
    func cancel(_ key: String) {
        guard let task = running[key] else { return }
        cancelled.insert(key)
        task.cancel()
    }

    func startLegacySession(writes: Bool) {
        isLegacySession = true
        lastListedWrites = writes
    }

    func markInitialized() { isLegacySession = true }

    func listedTools(writes: Bool) { lastListedWrites = writes }

    /// True once per change of the write permission since the client last listed the tools.
    func toolListChanged(writes: Bool) -> Bool {
        guard let last = lastListedWrites, last != writes else { return false }
        lastListedWrites = writes
        return true
    }
}
