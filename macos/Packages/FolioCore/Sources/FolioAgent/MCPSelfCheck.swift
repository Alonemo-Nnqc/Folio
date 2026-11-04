import Foundation

/// Starts folio-cli the way an agent does and talks MCP to it (设置 ▸ AI ▸ 检查 MCP 服务器): proves the
/// binary runs, answers the handshake, lists its tools and can read the library.
public enum MCPSelfCheck {
    public struct Report: Sendable {
        public var protocolVersion: String?
        public var toolCount = 0
        public var itemCount: Int?
        /// The library could not be read (the server itself works).
        public var libraryProblem: String?
        public var elapsed: Duration = .zero
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func run(cliPath: String, extraArguments: [String] = [], timeout: Duration = .seconds(15)) async throws -> Report {
        let clock = ContinuousClock()
        let start = clock.now
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw Failure(message: String(localized: "找不到 folio-cli：\(cliPath)", bundle: .module))
        }
        let process = Process()
        process.executableURL = URL(filePath: cliPath)
        process.arguments = extraArguments + ["mcp"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure(message: String(localized: "无法启动 folio-cli：\(error.localizedDescription)", bundle: .module))
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let requests: [JSONValue] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Folio 设置", "version": "1"]]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
            ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_collections", "arguments": [:]]],
        ]
        for request in requests {
            input.fileHandleForWriting.write(Data((request.wireLine + "\n").utf8))
        }
        var responses: [Int: JSONValue] = [:]
        let reader = Task.detached { () -> [Int: JSONValue] in
            var found: [Int: JSONValue] = [:]
            for await line in StdioTransport.messages(from: output.fileHandleForReading) {
                if let message = try? JSONValue.decode(line), let id = message["id"]?.intValue { found[id] = message }
                if found.count == 3 { break }
            }
            return found
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        responses = await reader.value
        timer.cancel()

        guard let initialize = responses[1] else {
            let reason = process.isRunning ? String(localized: "超时", bundle: .module)
                : String(localized: "进程已退出，状态 \(process.terminationStatus)", bundle: .module)
            throw Failure(message: String(localized: "folio-cli 没有响应 MCP 握手（\(reason)）。", bundle: .module))
        }
        if let error = initialize["error"]?["message"]?.stringValue { throw Failure(message: String(localized: "握手失败：\(error)", bundle: .module)) }
        var report = Report()
        report.protocolVersion = initialize["result"]?["protocolVersion"]?.stringValue
        report.toolCount = responses[2]?["result"]?["tools"]?.arrayValue?.count ?? 0
        if let call = responses[3]?["result"], let text = call["content"]?.arrayValue?.first?["text"]?.stringValue {
            if call["isError"] == true {
                report.libraryProblem = text
            } else {
                report.itemCount = (try? JSONValue.decode(text))?["all_items"]?.intValue
            }
        }
        report.elapsed = clock.now - start
        return report
    }
}
