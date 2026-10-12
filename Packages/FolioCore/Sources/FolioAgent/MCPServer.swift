import Foundation

/// A Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0) exposing the
/// library tools (AI-01). Hand-written rather than built on the Swift SDK: Folio only needs the
/// stdio transport and tools, and the SDK would add swift-nio and several other dependencies,
/// one of them tracking a moving branch.
public final class MCPServer: Sendable {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverVersion = "2.4"

    private let toolbox: LibraryToolbox

    public init(toolbox: LibraryToolbox) {
        self.toolbox = toolbox
    }

    /// Reads requests from stdin until it closes.
    public func run() async {
        log("Folio MCP server started")
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if let response = await handle(line: line) { write(response) }
            }
        } catch {
            log("stdin closed: \(error)")
        }
    }

    /// Handles one message; returns the response line, or nil for notifications.
    public func handle(line: String) async -> String? {
        guard let message = try? JSONValue.decode(line) else {
            return errorResponse(id: .null, code: -32700, message: "Parse error").encoded()
        }
        if case .array(let batch) = message {
            var responses: [JSONValue] = []
            for entry in batch { if let response = await handle(message: entry) { responses.append(response) } }
            return responses.isEmpty ? nil : JSONValue.array(responses).encoded()
        }
        return await handle(message: message)?.encoded()
    }

    func handle(message: JSONValue) async -> JSONValue? {
        guard let method = message["method"]?.stringValue else {
            // A response to something we never asked: ignore.
            return nil
        }
        let id = message["id"]
        let params = message["params"] ?? [:]
        guard let id else { return nil }   // notifications (initialized, cancelled …)
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? Self.supportedProtocolVersions[0]
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            return result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "folio", "title": "Folio 文献库", "version": .string(Self.serverVersion)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            let tools = await toolbox.tools.map(\.mcpDescription)
            return result(id: id, ["tools": .array(tools)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return errorResponse(id: id, code: -32602, message: "Missing tool name")
            }
            do {
                let output = try await toolbox.call(name, arguments: params["arguments"] ?? [:])
                return result(id: id, [
                    "content": [["type": "text", "text": .string(output.encoded(pretty: true))]],
                    "structuredContent": output,
                    "isError": false,
                ])
            } catch {
                return result(id: id, [
                    "content": [["type": "text", "text": .string(error.localizedDescription)]],
                    "isError": true,
                ])
            }
        case "resources/list":
            return result(id: id, ["resources": []])
        case "prompts/list":
            return result(id: id, ["prompts": []])
        default:
            return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static let instructions = """
    Folio is the user's reference manager on macOS. Use these tools to find papers in the user's own \
    library (search_library with several short keyword queries when the description is vague), read \
    them (get_item, read_fulltext, get_annotations, get_note), cite them (format_citations — present the \
    text exactly as returned), export them (export_references) and, when the user asks, add or organise \
    papers. Ask before move_to_trash. Item ids come from search results; DOIs and citation keys work too.
    """

    private func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    private func write(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data("[folio-mcp] \(text)\n".utf8))
    }
}
