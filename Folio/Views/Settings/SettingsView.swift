import AppKit
import SwiftUI

/// Settings window (4.16): 通用 / 文献库 / 检索 / 导入.
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(settings: model.settings, model: model)
                .tabItem { Label("通用", systemImage: "gearshape") }
            LibrarySettings(model: model)
                .tabItem { Label("文献库", systemImage: "books.vertical") }
            RetrievalSettings(settings: model.settings, model: model)
                .tabItem { Label("检索", systemImage: "magnifyingglass") }
            ImportSettings(model: model)
                .tabItem { Label("导入", systemImage: "square.and.arrow.down") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let model: AppModel

    var body: some View {
        Form {
            Picker("默认打开方式", selection: $settings.openWith) {
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
            Toggle("父分组中显示子分组的条目", isOn: $settings.includeSubgroupItems)
                .onChange(of: settings.includeSubgroupItems) { model.recompute() }
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

private struct LibrarySettings: View {
    let model: AppModel
    @State private var moving = false
    @State private var error: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
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
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Toggle("检索到元数据后按「作者_年份_标题」重命名文件", isOn: $settings.autoRenameFiles)
            Toggle("自动彻底删除回收站中超过 30 天的内容", isOn: $settings.autoPurgeTrash)
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
        do {
            _ = try model.relocateLibrary(into: parent)
            error = nil
        } catch {
            self.error = "无法移动文献库：\(error.localizedDescription)"
        }
        moving = false
    }
}

private struct RetrievalSettings: View {
    @Bindable var settings: AppSettings
    let model: AppModel

    var body: some View {
        Form {
            Section {
                TextField("联系邮箱（选填）", text: $settings.crossrefMailto, prompt: Text("name@example.com"))
                Text("填写后，Crossref 会把请求放进响应更快的礼貌访问池。邮箱只随检索请求发送给 Crossref 和 OpenAlex。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                SecureField("OpenAlex API Key（选填）", text: $settings.openAlexAPIKey)
                Text("OpenAlex 对不带 Key 的请求按 IP 限额，Key 可在 openalex.org 免费申请。不填也能正常检索：Crossref、arXiv 和 DBLP 已经能覆盖大多数论文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.crossrefMailto) { model.refreshResolver() }
        .onChange(of: settings.openAlexAPIKey) { model.refreshResolver() }
    }
}

private struct ImportSettings: View {
    let model: AppModel

    var body: some View {
        Form {
            LabeledContent("Zotero") {
                Button("从 Zotero 导入…") { model.activeSheet = .zoteroImport }
            }
            Text("读取 Zotero 数据库的副本，导入条目、PDF、分组和标签，不会修改 Zotero。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
