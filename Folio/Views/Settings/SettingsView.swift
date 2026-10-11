import AppKit
import SwiftUI

/// Settings window (4.16): AppKit toolbar tabs like System Settings' older panes, each pane a grouped
/// SwiftUI form. Changes apply immediately; there is no Save button.
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.canPropagateSelectedChildViewControllerTitle = true
        let panes: [(String, String, AnyView)] = [
            ("通用", "gearshape", AnyView(GeneralSettings(settings: model.settings, model: model))),
            ("阅读", "book.pages", AnyView(ReadingSettings(settings: model.settings))),
            ("文献库", "books.vertical", AnyView(LibrarySettings(model: model))),
            ("检索", "magnifyingglass", AnyView(RetrievalSettings(settings: model.settings, model: model))),
            ("翻译", "character.book.closed", AnyView(TranslationSettingsPane(model: model))),
            ("导入", "square.and.arrow.down", AnyView(ImportSettings(model: model))),
        ]
        for (title, symbol, view) in panes {
            let host = NSHostingController(rootView: view.frame(width: 560).fixedSize(horizontal: false, vertical: true))
            host.sizingOptions = [.preferredContentSize]
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("FolioSettingsWindow")
        window.setAccessibilityIdentifier("settingsWindow")
        super.init(window: window)
        let remembered = UserDefaults.standard.integer(forKey: "settingsPane")
        if tabs.tabViewItems.indices.contains(remembered) { tabs.selectedTabViewItemIndex = remembered }
        selection = tabs.observe(\.selectedTabViewItemIndex) { tabs, _ in
            MainActor.assumeIsolated { UserDefaults.standard.set(tabs.selectedTabViewItemIndex, forKey: "settingsPane") }
        }
    }

    private var selection: NSKeyValueObservation?

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible == false { window?.center() }
        super.showWindow(sender)
    }

    /// Opens a given pane by title (preview hooks, "翻译设置…" buttons).
    func select(pane title: String) {
        guard let tabs = window?.contentViewController as? NSTabViewController,
              let index = tabs.tabViewItems.firstIndex(where: { $0.label == title }) else { return }
        tabs.selectedTabViewItemIndex = index
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
