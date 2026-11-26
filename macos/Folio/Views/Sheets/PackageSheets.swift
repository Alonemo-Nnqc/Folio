import AppKit
import FolioCore
import FolioTranslate
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A `.foliolib` file (declared in Info.plist).
    static let folioPackage = UTType(filenameExtension: LibraryPackageInfo.fileExtension) ?? .data
}

extension AppModel {
    var settingsStores: SettingsPackage.Stores {
        .init(defaults: .standard, domain: Bundle.main.bundleIdentifier ?? "com.nnqc.Folio", translation: translations.secrets,
              journals: JournalMetricsCoordinator.store, glossary: .shared)
    }
}

/// What both sheets do while they work: a bar, and a way to stop.
private struct WorkView: View {
    let title: LocalizedStringKey
    let done: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            Text(title).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// A part of a package, with what is in it.
private struct PartToggle: View {
    let title: LocalizedStringKey
    let detail: Text
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                detail.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        }
        .toggleStyle(.checkbox)
    }
}

/// "打包导出文献库与设置…": what to pack → where → progress → done.
struct PackageExportSheet: View {
    let model: AppModel
    @Environment(\.sheetDismiss) private var dismiss
    @State private var library = true
    @State private var settings = true
    @State private var keys = false
    @State private var password = ""
    @State private var again = ""
    @State private var phase = Phase.ready
    @State private var work: Task<Void, Never>?

    private enum Phase: Equatable {
        case ready, working(done: Int, total: Int), finished(URL, LibraryExportSummary?), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("打包导出", systemImage: "shippingbox").font(.headline)
            content
            buttons
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready, .failed:
            VStack(alignment: .leading, spacing: 12) {
                PartToggle(title: "文献库", detail: Text("\(itemCount) 个条目、\(files.count) 个文件（\(size)），包括分组、标签、笔记、批注、译文和阅读进度，不包括回收站"), isOn: $library)
                PartToggle(title: "设置与配置", detail: Text("偏好设置、翻译服务、术语表、工具栏和列表的列"), isOn: $settings)
                VStack(alignment: .leading, spacing: 8) {
                    PartToggle(title: "包括 API Key", detail: Text("用密码加密，导入时输入同一密码"), isOn: $keys)
                    if keys, settings {
                        Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 8) {
                            GridRow { Text("密码"); SecureField("", text: $password).labelsHidden() }
                            GridRow { Text("确认密码"); SecureField("", text: $again).labelsHidden() }
                        }
                        .padding(.leading, 22)
                        if !again.isEmpty, again != password {
                            Text("两次输入的密码不同").font(.callout).foregroundStyle(.red).padding(.leading, 22)
                        }
                    }
                }
                .padding(.leading, 22)
                .disabled(!settings)
            }
            if case .failed(let message) = phase {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        case .working(let done, let total): WorkView(title: "正在打包 \(done) / \(total)…", done: done, total: total)
        case .finished(let url, let summary):
            VStack(alignment: .leading, spacing: 4) {
                Label("导出完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(url.lastPathComponent).textSelection(.enabled)
                Text("在另一台设备的 Folio 中选择 文件 ▸ 导入 Folio 包… 即可导入").foregroundStyle(.secondary)
                if let summary, summary.missingFiles > 0 {
                    Text("\(summary.missingFiles) 个文件已不在文献库文件夹中，没有打包").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            switch phase {
            case .finished(let url, _):
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]); dismiss() }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).glassProminentButtonStyle()
            case .working:
                Button("取消", role: .cancel) { work?.cancel() }.keyboardShortcut(.cancelAction)
            default:
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出…", action: choose).keyboardShortcut(.defaultAction).glassProminentButtonStyle().disabled(!isReady)
            }
        }
    }

    private var isReady: Bool {
        (library || settings) && !(settings && keys && (password.isEmpty || password != again))
    }
    private var itemCount: Int { model.snapshot.items.values.count { !$0.isTrashed } }
    private var files: [FileRecord] { model.snapshot.files.values.filter { model.snapshot.items[$0.itemId]?.isTrashed == false } }
    private var size: String { ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file) }

    private func choose() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.folioPackage]
        panel.canSelectHiddenExtension = true
        let date = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = (library ? "Folio" : String(localized: "Folio 设置")) + " \(date).\(LibraryPackageInfo.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url)
    }

    private func export(to url: URL) {
        // What is open and not saved yet belongs in it.
        model.readers.saveAll()
        model.markdownTabs.saveAll()
        let packed: Data?
        do {
            packed = settings ? try SettingsPackage.data(from: model.settingsStores, password: keys ? password : nil) : nil
        } catch {
            phase = .failed(String(localized: "导出失败：\(error.localizedDescription)"))
            return
        }
        let source = model.library, all = library
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        phase = .working(done: 0, total: all ? files.count : 1)
        let (progress, continuation) = AsyncStream<(Int, Int)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task {
            for await (done, total) in progress {
                if case .working = phase { phase = .working(done: done, total: total) }
            }
        }
        let job = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return try source.exportPackage(to: url, includingLibrary: all, settings: packed, appVersion: version) { continuation.yield(($0, $1)) }
        }
        work = Task {
            do {
                let summary = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                phase = .finished(url, all ? summary : nil)
            } catch is CancellationError {
                phase = .ready
            } catch {
                phase = .failed(String(localized: "导出失败：\(error.localizedDescription)"))
            }
        }
    }
}

/// "导入 Folio 包…": what is in it → progress → summary.
struct PackageImportSheet: View {
    let model: AppModel
    let url: URL
    @Environment(\.sheetDismiss) private var dismiss
    @State private var package: LibraryPackage?
    @State private var packed: SettingsPackage?
    @State private var library = true
    @State private var settings = true
    @State private var password = ""
    @State private var phase = Phase.reading
    @State private var wrongPassword = false
    @State private var work: Task<Void, Never>?

    private enum Phase: Equatable {
        case reading, ready, working(done: Int, total: Int), finished(LibraryImportSummary?, settings: Bool), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("导入 Folio 包", systemImage: "shippingbox").font(.headline)
            content
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .task { await read() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .reading: HStack { ProgressView().controlSize(.small); Text("正在读取…") }
        case .ready:
            if let package {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(url.lastPathComponent)，由 Folio \(package.info.app) 于 \(package.info.exported.formatted(date: .abbreviated, time: .shortened)) 导出")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if package.hasLibrary {
                        PartToggle(title: "文献库", detail: Text("\(package.info.items) 个条目、\(package.info.files) 个文件、\(package.info.groups) 个分组、\(package.info.tags) 个标签。合并到当前文献库：已有的文献不会重复，信息、笔记和批注以较新的为准，被换下的文件移到废纸篓"), isOn: $library)
                    }
                    if let packed {
                        PartToggle(title: "设置与配置", detail: Text("替换这台设备的设置，完成后重新启动 Folio。只导入你信任的文件"), isOn: $settings)
                        if packed.hasSecrets, settings {
                            VStack(alignment: .leading, spacing: 4) {
                                SecureField("API Key 的密码（留空则不导入 API Key）", text: $password)
                                    .onChange(of: password) { wrongPassword = false }
                                if wrongPassword { Text("密码不正确").font(.callout).foregroundStyle(.red) }
                            }
                            .padding(.leading, 22)
                        }
                    }
                }
            }
        case .working(let done, let total): WorkView(title: "正在导入 \(done) / \(total)…", done: done, total: total)
        case .finished(let summary, let settings):
            VStack(alignment: .leading, spacing: 4) {
                Label("导入完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if let summary {
                    Text("新增 \(summary.itemsAdded) 个条目、\(summary.filesAdded) 个文件、\(summary.groupsCreated) 个分组、\(summary.tagsCreated) 个标签")
                    if summary.itemsUpdated > 0 { Text("更新 \(summary.itemsUpdated) 个已有条目（\(summary.filesUpdated) 个文件换成较新的）") }
                    if summary.itemsUnchanged > 0 { Text("\(summary.itemsUnchanged) 个条目已是最新").foregroundStyle(.secondary) }
                    if summary.missingFiles > 0 { Text("\(summary.missingFiles) 个文件不在包中或已损坏").foregroundStyle(.secondary) }
                }
                if settings { Text("设置在重新启动 Folio 后生效") }
            }
            .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            switch phase {
            case .finished(_, let settings):
                // Until it starts again the old settings are in memory, and would be written over the new ones.
                if settings { Button("重新启动 Folio") { dismiss(); AppDelegate.relaunch() }.keyboardShortcut(.defaultAction).glassProminentButtonStyle() }
                else { Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).glassProminentButtonStyle() }
            case .working:
                Button("取消", role: .cancel) { work?.cancel() }.keyboardShortcut(.cancelAction)
            default:
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入", action: start).keyboardShortcut(.defaultAction).glassProminentButtonStyle()
                    .disabled(phase != .ready || !(library && package?.hasLibrary == true || settings && packed != nil))
            }
        }
    }

    private func read() async {
        let url = url
        do {
            let found = try await Task.detached { try LibraryPackage(url: url) }.value
            // Settings that cannot be read do not keep the library from being imported.
            packed = found.settings.flatMap { try? SettingsPackage($0) }
            guard found.hasLibrary || packed != nil else { throw ZipError.notAnArchive }
            package = found
            phase = .ready
        } catch {
            phase = .failed(String(localized: "无法读取「\(url.lastPathComponent)」：\(error.localizedDescription)"))
        }
    }

    private func start() {
        guard let package else { return }
        let applied = settings ? packed : nil
        var secrets: [String: String]?
        if let applied, applied.hasSecrets, !password.isEmpty {
            secrets = applied.secrets(password: password)
            if secrets == nil { wrongPassword = true; return }
        }
        let target = model.library, whole = library && package.hasLibrary
        if whole {
            // Papers and documents that are open may be replaced: what is in them is written, and they are closed.
            model.readers.saveAll()
            model.markdownTabs.saveAll()
            model.readers.closeAll()
        }
        phase = .working(done: 0, total: whole ? package.info.items : 1)
        let (progress, continuation) = AsyncStream<(Int, Int)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task {
            for await (done, total) in progress {
                if case .working = phase { phase = .working(done: done, total: total) }
            }
        }
        let job = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return whole ? try target.importPackage(package) { continuation.yield(($0, $1)) } : nil
        }
        work = Task {
            do {
                let summary = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                if let applied, !UserDefaults.standard.bool(forKey: "FolioUITesting") { try applied.apply(to: model.settingsStores, secrets: secrets) }
                phase = .finished(summary, settings: applied != nil)
            } catch is CancellationError {
                phase = .ready
            } catch {
                phase = .failed(String(localized: "导入失败：\(error.localizedDescription)"))
            }
            model.reloadReadingProgress()
            model.importer.indexFulltext()
            // Editors showing what came.
            for file in model.snapshot.files.values where file.isMarkdown { NotificationCenter.default.post(name: .folioMarkdownFileDidChange, object: file.id) }
            for id in model.snapshot.items.keys { NotificationCenter.default.post(name: .folioNoteDidChange, object: id) }
        }
    }
}
