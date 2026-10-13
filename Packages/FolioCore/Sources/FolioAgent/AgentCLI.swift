import Foundation

/// `folio-cli` command line (AI-02): the MCP server, plus every tool as a command for agents that
/// can run shell commands but have no MCP.
public enum AgentCLI {
    public static let usage = """
    folio-cli — Folio 文献库的 AI 接口

    用法：
      folio-cli mcp                          以 stdio 方式运行 MCP 服务器（供 Claude、Codex、Cursor 等智能体使用）
      folio-cli tools [--json]               列出所有工具（--json 输出参数结构）
      folio-cli call <工具> ['<JSON 参数>']   调用任一工具，结果为 JSON
      folio-cli search <关键词…> [--fulltext] [--limit N]
      folio-cli get <条目 id | DOI | 引用键>
      folio-cli cite <条目…> [--style apa|gbt7714|ieee|mla|chicago|harvard|vancouver|nature|bibtex] [--in-text]
      folio-cli export [--format bibtex|ris|csljson] [--collection <分组/标签>] [-o <文件>]
      folio-cli add <DOI | arXiv ID | ISBN | PDF 路径> [--group <分组>]
      folio-cli open <条目> [--page N]
      folio-cli status                       文献库位置、条目数量、是否允许修改（排查连接问题）

    选项：--library <目录> 使用指定文献库；--read-only 只允许读取。
    """

    /// Runs a command; returns the process exit status.
    public static func main(_ arguments: [String]) async -> Int32 {
        var args = arguments
        let configuration = AgentConfiguration.resolve(arguments: args)
        args = strip(args, option: "--library", hasValue: true)
        args = strip(args, option: "--read-only", hasValue: false)
        guard let command = args.first else {
            print(usage)
            return 0
        }
        let rest = Array(args.dropFirst())
        if ["help", "--help", "-h"].contains(command) {
            print(usage)
            return 0
        }
        if command == "version" || command == "--version" {
            print("folio-cli \(MCPServer.serverVersion)")
            return 0
        }
        if command == "mcp" {
            // The server always starts, so the agent can connect and hear why the library is unavailable
            // (and recovers by itself once Folio has created it or the location is fixed).
            let toolbox = LibraryToolbox(configurationSource: { AgentConfiguration.resolve(arguments: arguments) })
            await MCPServer(toolbox: toolbox).run()
            return 0
        }
        if command == "status" {
            return status(configuration)
        }
        let toolbox: LibraryToolbox
        do {
            toolbox = try LibraryToolbox(configuration: configuration)
        } catch {
            printError("无法打开文献库 \(configuration.libraryRoot.path)：\(error.localizedDescription)")
            return 2
        }
        switch command {
        case "tools":
            let tools = await toolbox.tools
            if rest.contains("--json") {
                print(JSONValue.array(tools.map(\.mcpDescription)).encoded(pretty: true))
            } else {
                for tool in tools {
                    print("\(tool.name)\(tool.writes ? "  [修改]" : "")\n    \(tool.description.replacingOccurrences(of: "\n", with: " "))\n")
                }
            }
            return 0
        case "call":
            guard let name = rest.first else {
                printError("用法：folio-cli call <工具> '<JSON 参数>'")
                return 64
            }
            let arguments: JSONValue
            do {
                arguments = rest.count > 1 ? try JSONValue.decode(rest[1]) : [:]
            } catch {
                printError("参数不是合法的 JSON：\(rest[1])")
                return 64
            }
            return await run(toolbox, name, arguments)
        case "search":
            let limit = value(of: "--limit", in: rest).flatMap(Int.init) ?? 20
            let words = positional(rest, valueOptions: ["--limit"]).joined(separator: " ")
            return await run(toolbox, "search_library",
                             ["query": .string(words), "include_fulltext": .bool(rest.contains("--fulltext")), "limit": .from(limit)])
        case "get":
            return await run(toolbox, "get_item", ["item": .from(rest.first)])
        case "cite":
            let style = value(of: "--style", in: rest) ?? "apa"
            let items = positional(rest, valueOptions: ["--style"])
            let inText = rest.contains("--in-text")
            return await run(toolbox, "format_citations", ["items": .array(items.map(JSONValue.string)), "style": .string(style),
                                                           "mode": inText ? "both" : "bibliography"],
                             textKey: inText ? nil : "text")
        case "export":
            var arguments: [String: JSONValue] = ["format": .string(value(of: "--format", in: rest) ?? "bibtex")]
            if let collection = value(of: "--collection", in: rest) { arguments["collection"] = .string(collection) }
            if let path = value(of: "-o", in: rest) ?? value(of: "--output", in: rest) { arguments["path"] = .string(path) }
            return await run(toolbox, "export_references", .object(arguments), textKey: "text")
        case "add":
            guard let target = positional(rest, valueOptions: ["--group"]).first else {
                printError("用法：folio-cli add <DOI | arXiv ID | ISBN | PDF 路径>")
                return 64
            }
            var arguments: [String: JSONValue] = [:]
            if let group = value(of: "--group", in: rest) { arguments["group"] = .string(group) }
            if FileManager.default.fileExists(atPath: (target as NSString).expandingTildeInPath) {
                arguments["path"] = .string(target)
                return await run(toolbox, "add_pdf", .object(arguments))
            }
            arguments["identifier"] = .string(target)
            return await run(toolbox, "add_item_by_identifier", .object(arguments))
        case "open":
            var arguments: [String: JSONValue] = ["item": .from(positional(rest, valueOptions: ["--page"]).first)]
            if let page = value(of: "--page", in: rest).flatMap(Int.init) { arguments["page"] = .from(page) }
            return await run(toolbox, "open_in_folio", .object(arguments))
        default:
            // `folio-cli <tool> '<json>'` also works.
            if ToolCatalog.tool(named: command) != nil {
                let arguments = (rest.first.flatMap { try? JSONValue.decode($0) }) ?? [:]
                return await run(toolbox, command, arguments)
            }
            printError("未知命令：\(command)\n\n\(usage)")
            return 64
        }
    }

    /// Where folio-cli looks and what it may do — the first thing to check when an agent cannot use Folio.
    private static func status(_ configuration: AgentConfiguration) -> Int32 {
        let root = configuration.libraryRoot.path
        print("folio-cli \(MCPServer.serverVersion)（MCP 协议 \(MCPServer.supportedProtocolVersions.joined(separator: ", "))）")
        print("可执行文件：\(Bundle.main.executablePath ?? CommandLine.arguments[0])")
        print("文献库：\(root)")
        do {
            let library = try LibraryToolbox.open(configuration.libraryRoot)
            let snapshot = try library.snapshot()
            let active = snapshot.items.values.filter { !$0.isTrashed }.count
            print("条目：\(active)（回收站 \(snapshot.items.count - active)），分组 \(snapshot.groupsById.count)，标签 \(snapshot.tags.count)")
        } catch {
            printError("无法打开文献库：\(error.localizedDescription)")
            return 2
        }
        print("允许 AI 修改文献库：\(configuration.allowWrites ? "是" : "否（只读）")")
        print("工具：\(ToolCatalog.available(allowWrites: configuration.allowWrites).count) 个")
        return 0
    }

    /// Prints the result as JSON (or one text field of it, for citations and exports).
    private static func run(_ toolbox: LibraryToolbox, _ name: String, _ arguments: JSONValue, textKey: String? = nil) async -> Int32 {
        do {
            let result = try await toolbox.call(name, arguments: arguments)
            if let textKey, let text = result[textKey]?.stringValue {
                print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
            } else {
                print(result.pruned.encoded(pretty: true))
            }
            return 0
        } catch {
            printError(error.localizedDescription)
            return 1
        }
    }

    private static func value(of option: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: option), args.indices.contains(index + 1) else { return nil }
        return args[index + 1]
    }

    /// Arguments that are not options (or option values).
    private static func positional(_ args: [String], valueOptions: Set<String>) -> [String] {
        var result: [String] = []
        var skip = false
        for arg in args {
            if skip { skip = false; continue }
            if valueOptions.contains(arg) { skip = true; continue }
            if arg.hasPrefix("--") { continue }
            result.append(arg)
        }
        return result
    }

    private static func strip(_ args: [String], option: String, hasValue: Bool) -> [String] {
        guard let index = args.firstIndex(of: option) else { return args }
        var copy = args
        copy.removeSubrange(index..<min(index + (hasValue ? 2 : 1), copy.count))
        return copy
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
