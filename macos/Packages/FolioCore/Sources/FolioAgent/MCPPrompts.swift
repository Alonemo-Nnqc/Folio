import Foundation

/// MCP prompts: ready-made requests the user can pick in an agent's slash-command menu
/// (e.g. `/mcp__folio__find_paper` in Claude Code).
struct MCPPrompt: Sendable {
    struct Argument: Sendable {
        let name: String
        let description: String
        let required: Bool
    }

    let name: String
    let title: String
    let description: String
    let arguments: [Argument]
    /// Builds the request from the arguments (all strings).
    let text: @Sendable ([String: String]) -> String

    var listEntry: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "arguments": .array(arguments.map {
                ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)]
            }),
        ]
    }

    func messages(arguments values: JSONValue) throws -> [String: JSONValue] {
        var strings: [String: String] = [:]
        for argument in arguments {
            let value = values[argument.name]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty && argument.required { throw ToolError("Missing argument \"\(argument.name)\".") }
            strings[argument.name] = value
        }
        return [
            "description": .string(description),
            "messages": [["role": "user", "content": ["type": "text", "text": .string(text(strings))]]],
        ]
    }
}

enum MCPPrompts {
    static let all: [MCPPrompt] = [
        MCPPrompt(
            name: "find_paper", title: "在 Folio 中查找论文",
            description: "根据模糊的描述在 Folio 文献库中找到对应的论文",
            arguments: [.init(name: "description", description: "对论文的描述，例如“那篇用 Mamba 做视网膜血管分割的”", required: true)],
            text: { args in
                """
                Find the paper in my Folio library that matches this description: \(args["description"] ?? "")

                Use search_library with several short keyword queries (topic words, acronyms, an author's family name, a year); \
                try include_fulltext and filters if nothing convincing turns up. Confirm with get_item. If several papers fit, \
                list them (title, first author, year) and ask me which one. Answer in my language and include the folio:// link.
                """
            }),
        MCPPrompt(
            name: "cite_papers", title: "引用 Folio 中的论文",
            description: "生成指定格式的参考文献列表和文中引用",
            arguments: [
                .init(name: "papers", description: "要引用的论文（标题、关键词、DOI 或引用键，多篇用分号隔开）", required: true),
                .init(name: "style", description: "引用格式：apa、gbt7714、ieee、mla、chicago、harvard、vancouver、nature 或 bibtex（默认 apa）", required: false),
            ],
            text: { args in
                let style = (args["style"] ?? "").isEmpty ? "apa" : args["style"]!
                return """
                Cite these papers from my Folio library in the \(style) style: \(args["papers"] ?? "")

                Find each one with search_library (ask me if a description matches several papers), then call format_citations \
                with all of them, style "\(style)" and mode "both". Give me the reference list and the in-text citations exactly \
                as returned — do not reformat them. Tell me about any paper you could not find.
                """
            }),
        MCPPrompt(
            name: "summarize_paper", title: "总结 Folio 中的论文",
            description: "阅读论文全文和你的批注，给出带页码的总结，可保存到笔记",
            arguments: [
                .init(name: "paper", description: "论文（标题、关键词、DOI 或引用键）", required: true),
                .init(name: "focus", description: "可选：重点关注的方面，例如“方法”“实验设置”", required: false),
            ],
            text: { args in
                let focus = (args["focus"] ?? "").isEmpty ? "" : " Focus on: \(args["focus"]!)."
                return """
                Summarize this paper from my Folio library: \(args["paper"] ?? "").\(focus)

                Find it with search_library and get_item, read it with read_fulltext (page ranges; follow next_start_page), and \
                look at what I highlighted with get_annotations. Cite page numbers. Answer in my language. At the end, offer to \
                save the summary to the paper's note with set_note (mode "append").
                """
            }),
    ]

    static func prompt(named name: String) -> MCPPrompt? { all.first { $0.name == name } }
}
