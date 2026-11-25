import AppKit
import FolioCore

/// A paper that can be cited in a document: what the menu shows, and the Markdown link put into the text.
struct MarkdownReference: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var markdown: String
}

/// A tool of the Markdown editor: in the menu "/" opens, in the menu of a line's handle, in the document toolbar.
struct MarkdownCommand: Identifiable {
    enum Section: Int, CaseIterable {
        case style, list, block, insert
        var title: String {
            switch self {
            case .style: String(localized: "文字")
            case .list: String(localized: "列表")
            case .block: String(localized: "区块")
            case .insert: String(localized: "插入")
            }
        }
    }

    var id: String
    var section: Section
    var title: String
    /// An SF Symbol, or the letters that stand for a heading ("H1"): the text-size symbols are words in Chinese.
    var symbol: String
    /// The Markdown it stands for, shown at the right of the menu.
    var hint: String
    /// What else finds it: pinyin and its initials, English.
    var keywords: [String]
    /// The kind it turns lines into (nil: it inserts something).
    var style: MarkdownTextView.BlockStyle?

    /// What typing `query` after "/" finds, best first: titles, then the start of a keyword, then anywhere in one.
    static func matching(_ query: String) -> [MarkdownCommand] {
        let query = normalized(query)
        guard !query.isEmpty else { return all }
        func rank(_ command: MarkdownCommand) -> Int? {
            let title = normalized(command.title)
            if title.hasPrefix(query) { return 0 }
            if command.keywords.contains(where: { $0.hasPrefix(query) }) { return 1 }
            if title.contains(query) { return 2 }
            return nil
        }
        return all.enumerated().compactMap { offset, command in rank(command).map { ($0, offset, command) } }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// Lower case without spaces or the apostrophes an input method puts between syllables ("biao'ti").
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !"'’‘".contains($0) }
    }

    static let all: [MarkdownCommand] = [
        .init(id: "text", section: .style, title: String(localized: "正文"), symbol: "T", hint: "", keywords: ["zhengwen", "zw", "text", "paragraph", "plain"], style: .text),
        .init(id: "h1", section: .style, title: String(localized: "标题 1"), symbol: "H1", hint: "#", keywords: ["biaoti1", "bt1", "heading1", "h1"], style: .heading(1)),
        .init(id: "h2", section: .style, title: String(localized: "标题 2"), symbol: "H2", hint: "##", keywords: ["biaoti2", "bt2", "heading2", "h2"], style: .heading(2)),
        .init(id: "h3", section: .style, title: String(localized: "标题 3"), symbol: "H3", hint: "###", keywords: ["biaoti3", "bt3", "heading3", "h3"], style: .heading(3)),
        .init(id: "bullet", section: .list, title: String(localized: "项目列表"), symbol: "list.bullet", hint: "-", keywords: ["xiangmuliebiao", "xmlb", "liebiao", "lb", "bullet", "list", "ul"], style: .bullet),
        .init(id: "numbered", section: .list, title: String(localized: "编号列表"), symbol: "list.number", hint: "1.", keywords: ["bianhaoliebiao", "bhlb", "liebiao", "lb", "numbered", "ordered", "ol"], style: .numbered),
        .init(id: "task", section: .list, title: String(localized: "任务列表"), symbol: "checklist", hint: "[ ]", keywords: ["renwuliebiao", "rwlb", "renwu", "daiban", "todo", "task", "checklist"], style: .task),
        .init(id: "quote", section: .block, title: String(localized: "引用块"), symbol: "text.quote", hint: ">", keywords: ["yinyong", "yy", "quote", "blockquote"], style: .quote),
        .init(id: "code", section: .block, title: String(localized: "代码块"), symbol: "curlybraces", hint: "```", keywords: ["daimakuai", "dmk", "daima", "code"], style: .code),
        .init(id: "table", section: .block, title: String(localized: "表格"), symbol: "tablecells", hint: "| |", keywords: ["biaoge", "bg", "table"], style: nil),
        .init(id: "rule", section: .block, title: String(localized: "分隔线"), symbol: "minus", hint: "---", keywords: ["fengexian", "fgx", "divider", "rule", "hr"], style: nil),
        .init(id: "cite", section: .insert, title: String(localized: "引用文献…"), symbol: "quote.opening", hint: "", keywords: ["yinyongwenxian", "yywx", "wenxian", "wx", "cite", "reference", "paper"], style: nil),
        .init(id: "link", section: .insert, title: String(localized: "链接"), symbol: "link", hint: "⌘K", keywords: ["lianjie", "lj", "link", "url"], style: nil),
        .init(id: "date", section: .insert, title: String(localized: "今天的日期"), symbol: "calendar", hint: "", keywords: ["jintianderiqi", "jtdrq", "riqi", "rq", "date", "today"], style: nil),
    ]

    var isLettered: Bool { symbol.count <= 2 }

    /// Its picture in a menu.
    var image: NSImage? {
        guard isLettered else { return NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        let text = NSAttributedString(string: symbol, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black])
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { rect in
            let size = text.size()
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Runs it at the caret (the line's kind is set, not toggled: a menu says what the line becomes).
    func run(in view: MarkdownTextView) {
        if let style {
            view.setBlockStyle(style)
            return
        }
        switch id {
        case "table": view.insertTable()
        case "rule": view.insertBlock("---")
        case "link": view.insertLink()
        case "date": view.insertText(Self.today, replacementRange: view.selectedRange())
        default: break
        }
    }

    static var today: String { Date.now.formatted(.iso8601.year().month().day()) }
}

extension AppModel {
    /// Papers to cite in a document, the most recently changed first; `query` finds title, authors and year.
    func markdownReferences(matching query: String) -> [MarkdownReference] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace || "'’".contains($0) }).map(String.init)
        return snapshot.items.values
            .filter { $0.kind == .regular && !$0.isTrashed }
            .sorted { ($0.dateModified, $0.id) > ($1.dateModified, $1.id) }
            .compactMap { item -> MarkdownReference? in
                let authors = item.authors.map(\.family).filter { !$0.isEmpty }
                let text = ([item.title, item.source ?? "", item.year.map { "\($0)" } ?? ""] + authors).joined(separator: " ").lowercased()
                guard terms.allSatisfy(text.contains) else { return nil }
                let chinese = item.title.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                let names = switch authors.count {
                case 0: ""
                case 1: authors[0]
                case 2: authors[0] + (chinese ? "、" : " & ") + authors[1]
                default: authors[0] + (chinese ? " 等" : " et al.")
                }
                let year = item.year.map { "\($0)" } ?? ""
                let detail = [names, year, item.source ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                let label = [names, year].filter { !$0.isEmpty }.joined(separator: ", ")
                let shown = (label.isEmpty ? item.title : label).replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
                return MarkdownReference(id: item.id, title: item.title, detail: detail, markdown: "[\(shown)](folio://open?item=\(item.id))")
            }
            .prefix(30).map { $0 }
    }
}
