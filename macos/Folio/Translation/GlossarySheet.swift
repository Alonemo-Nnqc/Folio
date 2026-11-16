import AppKit
import FolioTranslate
import SwiftUI
import UniformTypeIdentifiers

/// 设置 ▸ 翻译 ▸ 术语表: the glossary's row in the settings, with how many terms it has.
struct GlossarySettingsRows: View {
    let settings: AppSettings
    @State private var managing = false
    @State private var count = 0

    var body: some View {
        LabeledContent {
            HStack {
                Text("\(count) 条术语")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("管理…") { managing = true }
            }
        } label: {
            Text("术语表")
            Text("专业术语的固定译法，翻译每篇论文时都会使用")
        }
        .onAppear {
            refresh()
            // -FolioPreviewGlossary YES: the sheet, with a few sample terms that are not the user's (for looking at it).
            if UserDefaults.standard.bool(forKey: "FolioPreviewGlossary") { managing = true }
        }
        .onChange(of: settings.translationOptions.langOut) { refresh() }
        .sheet(isPresented: $managing, onDismiss: refresh) {
            GlossarySheet(language: settings.translationOptions.langOut,
                          store: UserDefaults.standard.bool(forKey: "FolioPreviewGlossary") ? GlossarySheet.sampleStore() : .shared)
        }
        Toggle(isOn: Binding(get: { settings.translationOptions.rememberTerms }, set: { settings.translationOptions.rememberTerms = $0 })) {
            Text("记住翻译时找到的术语")
            Text("模型从论文中提取的术语会加入术语表，之后翻译其他论文时沿用；你修改过的译法不会被覆盖")
        }
    }

    private func refresh() { count = GlossaryStore.shared.terms(language: settings.translationOptions.langOut).count }
}

/// The glossary: terms typed by the user and terms models found in the papers translated so far, by language. A term is
/// changed in its row; what is changed is saved at once.
struct GlossarySheet: View {
    @State private var language: String
    @Environment(\.dismiss) private var dismiss
    @State private var terms: [GlossaryTerm] = []
    @State private var selection: Set<GlossaryTerm.ID> = []
    @State private var query = ""
    @State private var newSource = ""
    @State private var newTarget = ""
    @FocusState private var addingFocused: Bool
    private let store: GlossaryStore

    init(language: String, store: GlossaryStore = .shared) {
        _language = State(initialValue: language)
        self.store = store
    }

    /// A glossary of its own with a few terms, in a temporary file: what the sheet looks like, without the user's terms.
    static func sampleStore() -> GlossaryStore {
        let store = GlossaryStore(url: FileManager.default.temporaryDirectory.appending(path: "folio-preview-glossary-\(UUID().uuidString).json"))
        store.save(GlossaryTerm(source: "domain generalization", target: "域泛化", language: "zh"))
        store.learn([GlossaryEntry(source: "semantic segmentation", target: "语义分割"), GlossaryEntry(source: "style augmentation", target: "风格增强"),
                     GlossaryEntry(source: "vision-language model", target: "视觉-语言模型"), GlossaryEntry(source: "fine-tuning", target: "微调")],
                    language: "zh", paper: "A Simple Recipe for Language-guided Domain Generalized Segmentation")
        store.learn([GlossaryEntry(source: "curvilinear structure", target: "曲线结构"), GlossaryEntry(source: "topological consistency", target: "拓扑一致性")],
                    language: "zh", paper: "Dual-level Adapter Boosting Prompt-free Curvilinear Structure Segmentation")
        return store
    }

    private var shown: [GlossaryTerm] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return terms }
        return terms.filter { $0.source.localizedCaseInsensitiveContains(needle) || $0.target.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("术语表").font(.headline)
                    Text("\(terms.count) 条术语")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Picker("译文语言", selection: $language) {
                    ForEach(TranslationOptions.commonLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .fixedSize()
                TextField("搜索", text: $query, prompt: Text("搜索"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Table(shown, selection: $selection) {
                TableColumn("") { term in
                    Toggle("启用", isOn: binding(term, \.isEnabled))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help("取消勾选后保留在列表中，但翻译时不使用")
                }
                .width(22)
                TableColumn("原文") { term in
                    TextField("原文", text: binding(term, \.source))
                        .textFieldStyle(.plain)
                }
                TableColumn("译文") { term in
                    TextField("译文", text: binding(term, \.target))
                        .textFieldStyle(.plain)
                }
                TableColumn("来源") { term in
                    Text(origin(of: term))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(term.paper ?? "")
                }
                .width(min: 80, ideal: 150)
            }
            .overlay {
                if terms.isEmpty {
                    ContentUnavailableView("还没有术语", systemImage: "character.book.closed",
                                           description: Text("在下方添加术语，或用大模型翻译一篇论文：提取到的术语会出现在这里"))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .onDeleteCommand(perform: removeSelected)

            HStack(spacing: 8) {
                TextField("原文", text: $newSource, prompt: Text("原文术语"))
                    .focused($addingFocused)
                TextField("译文", text: $newTarget, prompt: Text("译文"))
                    .onSubmit(add)
                Button("添加", action: add)
                    .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty || newTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            HStack {
                Button("删除", role: .destructive, action: removeSelected)
                    .disabled(selection.isEmpty)
                Button("导入…", action: importCSV)
                Button("导出…", action: exportCSV)
                    .disabled(terms.isEmpty)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 640, height: 520)
        .onAppear(perform: reload)
        .onChange(of: language) { selection = []; reload() }
    }

    private func reload() { terms = store.terms(language: language) }

    private func origin(of term: GlossaryTerm) -> String {
        switch term.origin {
        case .user: String(localized: "手动添加")
        case .extracted: term.paper.map { String(localized: "自动提取 · \($0)") } ?? String(localized: "自动提取")
        }
    }

    /// A field of a term: what is typed is saved at once (an emptied field is not: the term stays as it was on disk
    /// until it has both sides again).
    private func binding<Value>(_ term: GlossaryTerm, _ keyPath: WritableKeyPath<GlossaryTerm, Value>) -> Binding<Value> {
        Binding(get: { terms.first { $0.id == term.id }?[keyPath: keyPath] ?? term[keyPath: keyPath] },
                set: { value in
                    guard let index = terms.firstIndex(where: { $0.id == term.id }) else { return }
                    terms[index][keyPath: keyPath] = value
                    // A term the user changed is the user's: later papers do not put the model's version back.
                    if !(value is Bool) { terms[index].origin = .user }
                    store.save(terms[index])
                })
    }

    private func add() {
        guard store.save(GlossaryTerm(source: newSource, target: newTarget, language: language)) != nil else { return }
        newSource = ""
        newTarget = ""
        addingFocused = true
        reload()
    }

    private func removeSelected() {
        guard !selection.isEmpty else { return }
        store.remove(selection)
        selection = []
        reload()
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = String(localized: "选择术语表 CSV（两列：原文, 译文）")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importCSV(url, language: language)
        reload()
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = String(localized: "术语表") + "-\(language).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // With a byte order mark: Excel reads the Chinese in it as what it is.
        try? ("\u{FEFF}" + store.exportCSV(language: language)).write(to: url, atomically: true, encoding: .utf8)
    }
}
