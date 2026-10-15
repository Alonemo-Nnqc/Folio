import AppKit
import FolioCore
import FolioZotero
import SwiftUI

/// "从 Zotero 导入…" (ZOT-01…06): probe → options → import with progress → summary.
struct ZoteroImportSheet: View {
    let model: AppModel
    @Environment(\.sheetDismiss) private var dismiss
    @State private var directory = ZoteroLocator.defaultDataDirectory()
    @State private var report: ZoteroReadReport?
    @State private var includeAutomaticTags = false
    @State private var phase = Phase.probing

    enum Phase: Equatable {
        case probing, ready, importing(done: Int, total: Int), finished(BulkImportSummary), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("从 Zotero 导入", systemImage: "square.and.arrow.down.on.square")
                .font(.headline)
            directoryRow
            content
            buttons
        }
        .padding(20)
        .frame(width: 480)
        .task(id: directory) { await probe() }
    }

    private var directoryRow: some View {
        HStack {
            Text("数据目录").foregroundStyle(.secondary)
            Text(directory?.path ?? String(localized: "未找到 Zotero 数据目录"))
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("选择…", action: chooseDirectory)
                .disabled(isImporting)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .probing:
            HStack { ProgressView().controlSize(.small); Text("正在读取 Zotero 数据库…") }
        case .ready:
            if let report {
                VStack(alignment: .leading, spacing: 6) {
                    Text("将导入 \(report.regularItems) 个条目、\(report.standaloneFiles) 个独立文件、\(report.collections) 个分组、\(report.tags) 个标签。")
                    Text("跳过：\(report.skippedNotes) 条笔记、\(report.skippedAnnotations) 条 Zotero 批注、\(report.skippedSnapshots) 个网页快照、\(report.skippedTrashed) 个回收站条目。超过两级的分组会并入第二级。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("同时导入自动标签（\(report.automaticTagsAvailable) 个，来自出版商关键词和 arXiv 分类）",
                           isOn: $includeAutomaticTags)
                        .disabled(report.automaticTagsAvailable == 0)
                        .padding(.top, 4)
                    Text("只读取 Zotero 数据库的副本，不会修改 Zotero；PDF 会复制进 Folio 文献库，与已有文献重复的会跳过。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .importing(let done, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("正在导入 \(done) / \(total)…").font(.callout).foregroundStyle(.secondary)
            }
        case .finished(let summary):
            VStack(alignment: .leading, spacing: 4) {
                Label("导入完成", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("导入 \(summary.itemsImported) 个条目、\(summary.filesImported) 个文件，新建 \(summary.groupsCreated) 个分组、\(summary.tagsCreated) 个标签。")
                if summary.duplicatesSkipped > 0 || summary.missingFiles > 0 {
                    Text("跳过 \(summary.duplicatesSkipped) 个重复条目；\(summary.missingFiles) 个附件在 Zotero 中已找不到文件。")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            switch phase {
            case .finished:
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
            default:
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button("导入", action: startImport)
                    .keyboardShortcut(.defaultAction)
                    .glassProminentButtonStyle()
                    .disabled(phase != .ready)
            }
        }
    }

    private var isImporting: Bool {
        if case .importing = phase { true } else { false }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "选择包含 zotero.sqlite 的 Zotero 数据目录")
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url { directory = url }
    }

    private func probe() async {
        guard let directory else {
            phase = .failed(String(localized: "未找到 Zotero 数据目录，请点击「选择…」手动指定"))
            return
        }
        phase = .probing
        do {
            report = try await Task.detached { try ZoteroReader(dataDirectory: directory).probe() }.value
            phase = .ready
        } catch {
            phase = .failed(String(localized: "无法读取 Zotero 数据库：\(error.localizedDescription)"))
        }
    }

    private func startImport() {
        guard let directory else { return }
        var readOptions = ZoteroReadOptions()
        readOptions.includeAutomaticTags = includeAutomaticTags
        let options = readOptions
        let library = model.library
        let autoRename = model.settings.autoRenameFiles
        phase = .importing(done: 0, total: report.map { $0.regularItems + $0.standaloneFiles } ?? 0)
        let (progress, continuation) = AsyncStream<(Int, Int)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        Task {
            for await (done, total) in progress {
                if case .importing = phase { phase = .importing(done: done, total: total) }
            }
        }
        Task {
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    defer { continuation.finish() }
                    let (prepared, _) = try ZoteroReader(dataDirectory: directory).read(options: options)
                    return try library.importPrepared(prepared, autoRename: autoRename) { @Sendable done, total in
                        continuation.yield((done, total))
                    }
                }.value
                phase = .finished(summary)
                model.importer.indexFulltext()
            } catch {
                phase = .failed(String(localized: "导入失败：\(error.localizedDescription)"))
            }
        }
    }
}
