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
            RetrievalSettings(settings: model.settings)
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
        let destination = parent.appending(path: model.library.root.lastPathComponent, directoryHint: .isDirectory)
        guard destination.standardizedFileURL != model.library.root.standardizedFileURL else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            error = "目标位置已存在同名文件夹"
            return
        }
        moving = true
        let source = model.library.root
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            try model.reopenLibrary(at: destination)
            model.settings.libraryPath = destination.path
            error = nil
        } catch {
            self.error = "无法移动文献库：\(error.localizedDescription)"
            if !FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: destination, to: source)
            }
            try? model.reopenLibrary(at: source)
        }
        moving = false
    }
}

private struct RetrievalSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            TextField("联系邮箱（选填）", text: $settings.crossrefMailto, prompt: Text("name@example.com"))
            Text("填写后，Crossref 与 OpenAlex 会把请求放进响应更快的礼貌访问池。邮箱只随检索请求发送给这两个服务。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
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
