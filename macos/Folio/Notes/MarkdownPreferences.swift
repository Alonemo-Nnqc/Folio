import AppKit
import SwiftUI

extension Notification.Name {
    /// The look or the behaviour of Markdown editors changed in 设置 (or by zooming): all that are open follow.
    static let folioMarkdownPreferencesDidChange = Notification.Name("FolioMarkdownPreferencesDidChange")
}

/// 设置 ▸ Markdown: how documents and notes are set, and what the editor does by itself. The keys are the Windows app's too.
struct MarkdownPreferences: Equatable {
    enum Typeface: String, CaseIterable, Identifiable {
        case system, serif, rounded, mono
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: String(localized: "系统默认")
            case .serif: String(localized: "衬线")
            case .rounded: String(localized: "圆体")
            case .mono: String(localized: "等宽")
            }
        }
    }

    /// The text of documents in a tab, and of notes and documents in a side panel (points).
    var fontSize = 15.0
    var panelFontSize = 13.0
    /// How large documents in a tab, and what is in a side panel, are shown as a whole (1: actual size).
    var zoom = 1.0
    var panelZoom = 1.0
    var typeface = Typeface.system
    /// From one line to the next, in font sizes.
    var lineHeight = 1.6
    /// Between paragraphs, in font sizes.
    var paragraphSpacing = 0.4
    /// How much larger than usual headings are.
    var headingScale = 1.0
    /// Of the text's size.
    var codeScale = 0.9
    /// The widest lines of a document get (0: the window's).
    var readableWidth = 760.0
    /// Spaces of a step of indentation in code.
    var codeIndent = 4
    var showsHandles = true
    var showsPlaceholders = true
    var showsWordCount = true
    var highlightsCode = true
    var strikesDone = true
    var checksSpelling = false
    var slashMenu = true
    var continuesLists = true
    var completesSymbols = true
    var pastesLinks = true

    static let fontSizes = 10.0...32.0
    static let panelFontSizes = 10.0...24.0
    static let zooms = 0.5...3.0
    /// Those 放大 and 缩小 go through.
    static let zoomSteps = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let lineHeights = 1.2...2.4
    static let paragraphSpacings = 0.0...1.5
    static let headingScales = 0.8...1.4
    static let codeScales = 0.75...1.1
    static let widths: [(width: Double, title: String)] = [
        (620, String(localized: "窄")), (760, String(localized: "标准")), (920, String(localized: "宽")), (1120, String(localized: "更宽")), (0, String(localized: "整个窗口")),
    ]

    /// Those in use (set by `AppSettings`).
    static var current = MarkdownPreferences()

    func size(inPanel: Bool) -> Double { inPanel ? panelFontSize : fontSize }

    func zoom(inPanel: Bool) -> Double { inPanel ? panelZoom : zoom }

    mutating func setZoom(_ value: Double, inPanel: Bool) {
        let value = min(max((value * 100).rounded() / 100, Self.zooms.lowerBound), Self.zooms.upperBound)
        if inPanel { panelZoom = value } else { zoom = value }
    }

    /// The same look, whatever the zoom.
    func looksLike(_ other: MarkdownPreferences) -> Bool {
        var copy = other
        copy.zoom = zoom
        copy.panelZoom = panelZoom
        return copy == self
    }

    mutating func setSize(_ size: Double, inPanel: Bool) {
        let range = inPanel ? Self.panelFontSizes : Self.fontSizes
        let size = min(max((size * 2).rounded() / 2, range.lowerBound), range.upperBound)
        if inPanel { panelFontSize = size } else { fontSize = size }
    }

    // MARK: Stored

    private static let numbers: [(String, WritableKeyPath<MarkdownPreferences, Double>, ClosedRange<Double>)] = [
        ("markdownFontSize", \.fontSize, fontSizes), ("markdownPanelFontSize", \.panelFontSize, panelFontSizes), ("markdownLineHeight", \.lineHeight, lineHeights),
        ("markdownParagraphSpacing", \.paragraphSpacing, paragraphSpacings), ("markdownHeadingScale", \.headingScale, headingScales),
        ("markdownCodeScale", \.codeScale, codeScales), ("markdownZoom", \.zoom, zooms), ("markdownPanelZoom", \.panelZoom, zooms), ("markdownReadableWidth", \.readableWidth, 0...4000),
    ]
    private static let switches: [(String, WritableKeyPath<MarkdownPreferences, Bool>)] = [
        ("markdownShowsHandles", \.showsHandles), ("markdownShowsPlaceholders", \.showsPlaceholders), ("markdownShowsWordCount", \.showsWordCount),
        ("markdownHighlightsCode", \.highlightsCode), ("markdownStrikesDone", \.strikesDone), ("markdownChecksSpelling", \.checksSpelling),
        ("markdownSlashMenu", \.slashMenu), ("markdownContinuesLists", \.continuesLists), ("markdownCompletesSymbols", \.completesSymbols), ("markdownPastesLinks", \.pastesLinks),
    ]

    init() {}

    init(_ defaults: UserDefaults) {
        for (key, path, range) in Self.numbers {
            if let value = defaults.object(forKey: key) as? NSNumber { self[keyPath: path] = min(max(value.doubleValue, range.lowerBound), range.upperBound) }
        }
        for (key, path) in Self.switches where defaults.object(forKey: key) != nil { self[keyPath: path] = defaults.bool(forKey: key) }
        typeface = Typeface(rawValue: defaults.string(forKey: "markdownTypeface") ?? "") ?? .system
        if [2, 4, 8].contains(defaults.integer(forKey: "markdownCodeIndent")) { codeIndent = defaults.integer(forKey: "markdownCodeIndent") }
    }

    /// What differs from `old`, as it is stored.
    func changes(from old: MarkdownPreferences) -> [(String, Any)] {
        var result: [(String, Any)] = []
        for (key, path, _) in Self.numbers where self[keyPath: path] != old[keyPath: path] { result.append((key, self[keyPath: path])) }
        for (key, path) in Self.switches where self[keyPath: path] != old[keyPath: path] { result.append((key, self[keyPath: path])) }
        if typeface != old.typeface { result.append(("markdownTypeface", typeface.rawValue)) }
        if codeIndent != old.codeIndent { result.append(("markdownCodeIndent", codeIndent)) }
        return result
    }
}

// MARK: - 设置 ▸ Markdown

struct MarkdownSettingsPane: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                MarkdownSample(preferences: settings.markdown)
                    .listRowInsets(EdgeInsets())
            }
            Section("文字") {
                SizeRow(title: "文档字号", value: $settings.markdown.fontSize, range: MarkdownPreferences.fontSizes)
                SizeRow(title: "侧栏字号", value: $settings.markdown.panelFontSize, range: MarkdownPreferences.panelFontSizes)
                Picker("字体", selection: $settings.markdown.typeface) {
                    ForEach(MarkdownPreferences.Typeface.allCases) { Text($0.title).tag($0) }
                }
                ScaleRow(title: "标题大小", value: $settings.markdown.headingScale, range: MarkdownPreferences.headingScales, step: 0.05)
                ScaleRow(title: "代码字号", value: $settings.markdown.codeScale, range: MarkdownPreferences.codeScales, step: 0.05)
            }
            Section("间距") {
                NumberRow(title: "行高", value: $settings.markdown.lineHeight, range: MarkdownPreferences.lineHeights, step: 0.05, format: "%.2f")
                NumberRow(title: "段落间距", value: $settings.markdown.paragraphSpacing, range: MarkdownPreferences.paragraphSpacings, step: 0.1, format: "%.1f")
                Picker("文档宽度", selection: $settings.markdown.readableWidth) {
                    ForEach(MarkdownPreferences.widths, id: \.width) { Text($0.title).tag($0.width) }
                }
            }
            Section("显示") {
                Toggle("显示 Markdown 文档工具栏", isOn: $settings.markdownToolbar)
                Toggle("指针移到一行时显示手柄", isOn: $settings.markdown.showsHandles)
                Toggle("空行显示提示文字（标题 1、列表…）", isOn: $settings.markdown.showsPlaceholders)
                Toggle("显示字数", isOn: $settings.markdown.showsWordCount)
                Toggle("完成的任务加删除线", isOn: $settings.markdown.strikesDone)
            }
            Section("输入") {
                Toggle("输入“/”或“、”打开工具菜单", isOn: $settings.markdown.slashMenu)
                Toggle("回车延续列表和引用", isOn: $settings.markdown.continuesLists)
                Toggle("自动转换中文符号（》、【】、·）", isOn: $settings.markdown.completesSymbols)
                Toggle("选中文字粘贴网址时生成链接", isOn: $settings.markdown.pastesLinks)
                Toggle("检查拼写", isOn: $settings.markdown.checksSpelling)
            }
            Section("代码块") {
                Toggle("语法高亮", isOn: $settings.markdown.highlightsCode)
                Picker("缩进", selection: $settings.markdown.codeIndent) {
                    ForEach([2, 4, 8], id: \.self) { Text("\($0) 个空格").tag($0) }
                }
            }
            Section {
                ZoomRow(title: "文档缩放", value: $settings.markdown.zoom)
                ZoomRow(title: "侧栏缩放", value: $settings.markdown.panelZoom)
                LabeledContent("手势与快捷键") { Text("捏合、⌘+、⌘− 整页缩放，⌘0 或双指轻点两下恢复 100%").foregroundStyle(.secondary) }
                Button("恢复默认设置") { settings.markdown = MarkdownPreferences() }
                    .disabled(settings.markdown == MarkdownPreferences())
            }
        }
        .formStyle(.grouped)
    }
}

private struct SizeRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value }, set: { value = ($0 * 2).rounded() / 2 }), in: range).labelsHidden().frame(width: 170)
                Text(verbatim: value.formatted(.number.precision(.fractionLength(0...1))) + " pt").monospacedDigit().frame(width: 52, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ScaleRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range).labelsHidden().frame(width: 170)
                Text(verbatim: "\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 52, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ZoomRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value }, set: { value = ($0 * 20).rounded() / 20 }), in: MarkdownPreferences.zooms).labelsHidden().frame(width: 170)
                Text(verbatim: "\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 52, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NumberRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range).labelsHidden().frame(width: 170)
                Text(verbatim: String(format: format, value)).monospacedDigit().frame(width: 52, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}

/// What the settings make of a short document: the editor itself, read-only.
private struct MarkdownSample: NSViewRepresentable {
    let preferences: MarkdownPreferences

    func makeCoordinator() -> MarkdownEditorController {
        let controller = MarkdownEditorController(inPanel: false)
        controller.followsZoom = false
        controller.textView.isEditable = false
        controller.textView.isSelectable = false
        controller.textView.horizontalInset = 20
        controller.textView.verticalInset = 16
        controller.textView.limitsWidth = false
        let text = String(localized: "## 阅读笔记\n行高和段落间距决定读起来是否舒服。中英文混排时，**重点**、`code` 和 [链接](https://example.com) 都在同一行里。\n> 引用的一句话\n- 第一项\n- 第二项")
        controller.load(MarkdownSource(key: "sample", load: { text }, save: { _ in }, notification: Notification.Name("FolioMarkdownSample")))
        return controller
    }

    func makeNSView(context: Context) -> NSScrollView {
        let view = context.coordinator.scrollView
        view.hasVerticalScroller = false
        return view
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 500, height: 212)
    }
}
