import AppKit
import SwiftUI

/// Settings window (4.16), laid out like System Settings: panes listed in a sidebar on the left,
/// the selected pane's grouped form on the right. Changes apply immediately; there is no Save button.
final class SettingsWindowController: NSWindowController {
    private let navigation = SettingsNavigation()

    init(model: AppModel) {
        let host = NSHostingController(rootView: SettingsRootView(model: model, navigation: navigation))
        host.sceneBridgingOptions = [.toolbars]
        // The window keeps its own size; long panes scroll. (Sized to the content, the window grew as tall
        // as the longest form and that frame was saved.)
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(Self.defaultSize)
        window.minSize = NSSize(width: 640, height: 420)
        window.setFrameAutosaveName(Self.autosaveName)
        window.setAccessibilityIdentifier("settingsWindow")
        super.init(window: window)
        // The pane title is the window title, as in System Settings. Set from AppKit: SwiftUI's title
        // bridging sometimes leaves "未命名" when a pane updates itself while appearing.
        titleObserver = ObservationLoop { [weak self] in
            guard let self else { return }
            self.window?.title = self.navigation.pane.title
        }
    }

    private var titleObserver: ObservationLoop?
    /// Changed when the default size changes, so a frame saved by an earlier version is not restored.
    private static let autosaveName = "FolioSettingsWindow3"
    private static let defaultSize = NSSize(width: 780, height: 600)

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible == false, !(window?.setFrameUsingName(Self.autosaveName) ?? false) { window?.center() }
        super.showWindow(sender)
        DispatchQueue.main.async { [weak self] in self?.pinSidebar() }
    }

    /// The sidebar cannot be hidden, as in System Settings. The pane has no sidebar button, and SwiftUI's
    /// split view left a sidebar dragged to the edge at zero width with no way back; its visibility
    /// binding still reports both columns. So the AppKit split view item itself refuses to collapse.
    private func pinSidebar() {
        func splitViews(in view: NSView) -> [NSSplitView] {
            (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews)
        }
        guard let content = window?.contentView,
              let controller = splitViews(in: content).lazy.compactMap({ $0.delegate as? NSSplitViewController }).first,
              let sidebar = controller.splitViewItems.first else { return }
        sidebar.canCollapse = false
        sidebar.canCollapseFromWindowResize = false
        sidebar.minimumThickness = 180
        if sidebar.viewController.view.frame.width < sidebar.minimumThickness {
            controller.splitView.setPosition(200, ofDividerAt: 0)
        }
    }

    /// Opens a given pane by title (preview hooks, "打开设置" buttons). Old pane names map to where
    /// their settings live now.
    func select(pane title: String) {
        let moved = ["外观": "通用", "导入": "文献库"]
        let target = moved[title] ?? title
        if let pane = SettingsPane.allCases.first(where: { $0.title == target }) { navigation.pane = pane }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, reading, library, retrieval, translation, browser, ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "通用"
        case .reading: "阅读"
        case .library: "文献库"
        case .retrieval: "检索"
        case .translation: "翻译"
        case .browser: "浏览器"
        case .ai: "AI"
        }
    }

    /// Plain SF Symbols, tinted by the sidebar like any source list.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .reading: "book"
        case .library: "books.vertical"
        case .retrieval: "magnifyingglass"
        case .translation: "character.book.closed"
        case .browser: "safari"
        case .ai: "sparkles"
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
                Label(pane.title, systemImage: pane.symbol)
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
        case .reading: ReadingSettings(settings: model.settings)
        case .library: LibrarySettings(model: model)
        case .retrieval: RetrievalSettings(settings: model.settings, model: model)
        case .translation: TranslationSettingsPane(model: model)
        case .browser: BrowserSettingsPane(model: model)
        case .ai: AISettingsPane(settings: model.settings)
        }
    }
}

/// 外观: 自动 / 浅色 / 深色 with System Settings-style previews.
struct AppearancePicker: View {
    @Bindable var settings: AppSettings

    var body: some View {
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
            Section("外观") {
                AppearancePicker(settings: settings)
                LabeledContent("边栏图标大小") {
                    Button("在系统设置中更改…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension")!)
                    }
                }
            }
            Section("打开") {
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
                Toggle("打开未读的论文时，标为\"在读\"", isOn: $settings.markReadingOnOpen)
                Toggle("启动时重新打开上次的论文标签页", isOn: $settings.reopenReaderTabs)
            }
            Section("列表") {
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
            Section("页面") {
                Picker("首次打开时的缩放", selection: $settings.readerZoom) {
                    ForEach(AppSettings.ReaderZoom.allCases) { Text($0.title).tag($0) }
                }
                Picker("显示方式", selection: $settings.readerLayout) {
                    ForEach(AppSettings.ReaderLayout.allCases) { Text($0.title).tag($0) }
                }
                Toggle("显示页面阴影", isOn: $settings.readerPageShadows)
            }
            Section("批注") {
                LabeledContent("默认高亮颜色") {
                    ColorSwatchRow(hex: Binding(
                        get: { AnnotationColor(rawValue: settings.highlightColor)?.nsColor.hexString },
                        set: { hex in
                            if let match = AnnotationColor.allCases.first(where: { $0.nsColor.hexString == hex }) {
                                settings.highlightColor = match.rawValue
                            }
                        }),
                        presets: AnnotationColor.allCases.map { ($0.title, $0.nsColor.hexString) }, allowsCustom: false)
                }
                TextField("批注作者", text: $settings.annotationAuthor, prompt: Text(NSFullUserName()))
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
            Section("文件") {
                Toggle("检索到元数据后按「作者_年份_标题」重命名文件", isOn: $settings.autoRenameFiles)
                Toggle("自动彻底删除回收站中超过 30 天的内容", isOn: $settings.autoPurgeTrash)
            }
            Section {
                LabeledContent("Zotero") {
                    Button("从 Zotero 导入…") {
                        AppDelegate.shared.showLibrary(nil)
                        model.activeSheet = .zoteroImport
                    }
                }
            } header: {
                Text("导入")
            } footer: {
                Text("导入条目、PDF、分组和标签，不会修改 Zotero。")
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
                Toggle("添加 PDF 后自动检索元数据", isOn: $settings.autoRetrieveOnImport)
                Toggle(isOn: $settings.useZoteroRecognizer) {
                    Text("使用 Zotero 识别服务")
                    Text("会把 PDF 前 5 页的文字发送给 Zotero，无需账号。")
                }
            }
            Section {
                TextField("联系邮箱（选填）", text: $settings.crossrefMailto, prompt: Text(verbatim: "name@example.com"))
                    .help("Crossref 会更快地响应带联系邮箱的请求；邮箱只发送给 Crossref 和 OpenAlex")
                SecureField("OpenAlex API Key（选填）", text: $settings.openAlexAPIKey)
                    .help("可在 openalex.org 免费申请，用于提高 OpenAlex 的访问额度")
            } footer: {
                Text("选填，可让检索更快、更稳定；不填也能正常检索。")
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.crossrefMailto) { model.refreshResolver() }
        .onChange(of: settings.openAlexAPIKey) { model.refreshResolver() }
        .onChange(of: settings.useZoteroRecognizer) { model.refreshResolver() }
    }
}
