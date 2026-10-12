import AppKit
import SwiftUI

/// Settings window (4.16), laid out like System Settings: panes listed in a sidebar on the left,
/// the selected pane's grouped form on the right. Changes apply immediately; there is no Save button.
final class SettingsWindowController: NSWindowController {
    private let navigation = SettingsNavigation()

    init(model: AppModel) {
        let host = NSHostingController(rootView: SettingsRootView(model: model, navigation: navigation))
        // The pane title becomes the window title, as in System Settings.
        host.sceneBridgingOptions = [.title, .toolbars]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName("FolioSettingsWindow2")
        window.setAccessibilityIdentifier("settingsWindow")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible == false, !(window?.setFrameUsingName("FolioSettingsWindow2") ?? false) { window?.center() }
        super.showWindow(sender)
    }

    /// Opens a given pane by title (preview hooks, "打开设置" buttons).
    func select(pane title: String) {
        if let pane = SettingsPane.allCases.first(where: { $0.title == title }) { navigation.pane = pane }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, reading, library, retrieval, translation, importing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .appearance: "外观"
        case .reading: "阅读"
        case .library: "文献库"
        case .retrieval: "检索"
        case .translation: "翻译"
        case .importing: "导入"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "circle.lefthalf.filled"
        case .reading: "book.pages.fill"
        case .library: "books.vertical.fill"
        case .retrieval: "magnifyingglass"
        case .translation: "character.book.closed.fill"
        case .importing: "square.and.arrow.down.fill"
        }
    }

    /// Icon tile colour, System Settings style.
    var tint: Color {
        switch self {
        case .general: .gray
        case .appearance: Color(white: 0.15)
        case .reading: .orange
        case .library: .brown
        case .retrieval: .blue
        case .translation: .green
        case .importing: .purple
        }
    }
}

@Observable
final class SettingsNavigation {
    var pane: SettingsPane = SettingsPane(rawValue: UserDefaults.standard.string(forKey: "settingsPane") ?? "") ?? .general {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane") }
    }
}

struct SettingsRootView: View {
    let model: AppModel
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(symbol: pane.symbol, tint: pane.tint)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(navigation.pane.title)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.pane {
        case .general: GeneralSettings(settings: model.settings, model: model)
        case .appearance: AppearanceSettings(settings: model.settings)
        case .reading: ReadingSettings(settings: model.settings)
        case .library: LibrarySettings(model: model)
        case .retrieval: RetrievalSettings(settings: model.settings, model: model)
        case .translation: TranslationSettingsPane(model: model)
        case .importing: ImportSettings(model: model)
        }
    }
}

/// White symbol on a coloured rounded square, like the icons in System Settings.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// 外观: 自动 / 浅色 / 深色, with System Settings-style previews.
struct AppearanceSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                HStack(spacing: 22) {
                    Spacer(minLength: 0)
                    ForEach(AppSettings.Appearance.allCases) { option in
                        Button {
                            settings.appearance = option
                        } label: {
                            VStack(spacing: 6) {
                                AppearancePreview(option: option)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(settings.appearance == option ? Color.accentColor : .clear, lineWidth: 3)
                                            .padding(-3)
                                    }
                                Text(option.title)
                                    .font(.callout)
                                    .foregroundStyle(settings.appearance == option ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("外观：\(option.title)")
                        .accessibilityAddTraits(settings.appearance == option ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            } header: {
                Text("外观")
            } footer: {
                Text("\"自动\"会跟随系统在浅色和深色之间切换。阅读器中的 PDF 页面始终按原样显示。")
            }
            Section {
                LabeledContent("边栏图标大小") {
                    Button("在系统设置中更改…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension")!)
                    }
                }
            } footer: {
                Text("边栏的行高和字号跟随系统设置 ▸ 外观 ▸ 边栏图标大小。")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearancePreview: View {
    let option: AppSettings.Appearance

    var body: some View {
        ZStack {
            switch option {
            case .light: window(dark: false)
            case .dark: window(dark: true)
            case .system:
                window(dark: false)
                    .overlay(alignment: .trailing) {
                        window(dark: true).mask(Rectangle().frame(width: 40).frame(maxWidth: .infinity, alignment: .trailing))
                    }
            }
        }
        .frame(width: 80, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func window(dark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: dark ? [Color(white: 0.25), Color(white: 0.12)] : [Color(red: 0.62, green: 0.78, blue: 0.95), Color(red: 0.85, green: 0.9, blue: 0.98)],
                           startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 3)
                .fill(dark ? Color(white: 0.18) : .white)
                .frame(width: 56, height: 34)
                .overlay(alignment: .leading) {
                    Rectangle().fill(dark ? Color(white: 0.28) : Color(white: 0.9)).frame(width: 16)
                }
                .padding(.leading, 12)
                .padding(.top, 10)
        }
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("打开 PDF 时使用", selection: $settings.openWith) {
                    ForEach(AppSettings.OpenWith.allCases) { Text($0.title).tag($0) }
                }
                if settings.openWith == .custom {
                    LabeledContent("应用") {
                        HStack {
                            Text(settings.openWithAppPath.isEmpty ? "未选择"
                                 : FileManager.default.displayName(atPath: settings.openWithAppPath))
                                .foregroundStyle(.secondary)
                            Button("选择…", action: chooseApp)
                        }
                    }
                }
            } footer: {
                Text("其他类型的文件总是用系统默认应用打开。在条目上右键选择\"打开方式\"可以临时换用其他应用。")
            }
            Section {
                Toggle("父分组中显示子分组的条目", isOn: $settings.includeSubgroupItems)
                    .onChange(of: settings.includeSubgroupItems) { model.recompute() }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url { settings.openWithAppPath = url.path }
    }
}

struct ReadingSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("首次打开时的缩放", selection: $settings.readerZoom) {
                    ForEach(AppSettings.ReaderZoom.allCases) { Text($0.title).tag($0) }
                }
                Picker("显示方式", selection: $settings.readerLayout) {
                    ForEach(AppSettings.ReaderLayout.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("再次打开读过的论文时，会回到上次的页码、位置和缩放。")
            }
            Section {
                Picker("默认高亮颜色", selection: $settings.highlightColor) {
                    ForEach(AnnotationColor.allCases) { color in
                        Label {
                            Text(color.title)
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: color.nsColor))
                        }
                        .tag(color.rawValue)
                    }
                }
                Toggle("启动时重新打开上次的论文标签页", isOn: $settings.reopenReaderTabs)
            }
        }
        .formStyle(.grouped)
    }
}

struct LibrarySettings: View {
    let model: AppModel
    @State private var moving = false
    @State private var error: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                LabeledContent("文献库位置") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(model.library.root.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.library.root]) }
                            Button("更改…", action: changeLocation).disabled(moving)
                        }
                    }
                }
                if moving {
                    ProgressView("正在移动文献库…").controlSize(.small)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            Section {
                Toggle("检索到元数据后按「作者_年份_标题」重命名文件", isOn: $settings.autoRenameFiles)
                Toggle("自动彻底删除回收站中超过 30 天的内容", isOn: $settings.autoPurgeTrash)
            }
        }
        .formStyle(.grouped)
    }

    /// Moves the whole library folder into the chosen directory and reopens it there (STORE-01).
    private func changeLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "移到这里"
        panel.message = "选择新的文献库位置，Folio 会把整个文献库移动过去"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        moving = true
        error = nil
        // Moving a big library can take a while: let the progress indicator draw first.
        DispatchQueue.main.async {
            do {
                _ = try model.relocateLibrary(into: parent)
            } catch {
                self.error = "无法移动文献库：\(error.localizedDescription)"
            }
            moving = false
        }
    }
}

struct RetrievalSettings: View {
    @Bindable var settings: AppSettings
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.useZoteroRecognizer) {
                    Text("使用 Zotero 识别服务")
                    Text("把 PDF 前 5 页的文字和版面（每篇约 0.5 MB）发送给 Zotero 的识别服务，不需要账号，Zotero 声明不记录内容。开放数据源检索不畅时仍能识别。关闭后只使用开放数据源。")
                }
            }
            Section {
                TextField("联系邮箱（选填）", text: $settings.crossrefMailto, prompt: Text("name@example.com"))
            } footer: {
                Text("填写后，Crossref 会把请求放进响应更快的礼貌访问池。邮箱只随检索请求发送给 Crossref 和 OpenAlex。")
            }
            Section {
                SecureField("OpenAlex API Key（选填）", text: $settings.openAlexAPIKey)
            } footer: {
                Text("OpenAlex 对不带 Key 的请求按 IP 限额，Key 可在 openalex.org 免费申请。不填也能正常检索。")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.crossrefMailto) { model.refreshResolver() }
        .onChange(of: settings.openAlexAPIKey) { model.refreshResolver() }
        .onChange(of: settings.useZoteroRecognizer) { model.refreshResolver() }
    }
}

struct ImportSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Zotero") {
                    Button("从 Zotero 导入…") {
                        AppDelegate.shared.showLibrary(nil)
                        model.activeSheet = .zoteroImport
                    }
                }
            } footer: {
                Text("读取 Zotero 数据库的副本，导入条目、PDF、分组和标签，不会修改 Zotero。")
            }
        }
        .formStyle(.grouped)
    }
}
