import FolioCore
import SwiftUI

/// Read-only list of highlights and notes found in the item's PDFs (INSP-03).
struct AnnotationsInspector: View {
    let model: AppModel
    let item: Item
    @State private var groups: [(file: FileRecord, annotations: [PDFAnnotationInfo])] = []
    @State private var loading = true
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            TextField("搜索标注", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
            if loading {
                ProgressView().frame(maxHeight: .infinity)
            } else if filtered.allSatisfy({ $0.annotations.isEmpty }) {
                ContentUnavailableView(query.isEmpty ? "没有标注" : "没有匹配的标注", systemImage: "highlighter",
                                       description: Text(query.isEmpty ? "在预览等阅读器中添加的高亮和注释会显示在这里" : ""))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(filtered, id: \.file.id) { group in
                            if !group.annotations.isEmpty { fileSection(group.file, group.annotations) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .task(id: fingerprint) { await load() }
    }

    /// Reloads when files change on disk (e.g. new highlights added in Preview).
    private var fingerprint: String {
        model.snapshot.files(of: item.id).map { "\($0.id)-\($0.sha256)" }.joined()
    }

    private var filtered: [(file: FileRecord, annotations: [PDFAnnotationInfo])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.map { group in
            (group.file, group.annotations.filter { ($0.quotedText + " " + $0.comment).lowercased().contains(q) })
        }
    }

    private func load() async {
        loading = true
        let files = model.snapshot.files(of: item.id).filter(\.isPDF)
        let urls = files.map(model.fileURL)
        let results = await Task.detached(priority: .userInitiated) {
            urls.map { AnnotationReader.annotations(in: $0) }
        }.value
        groups = Array(zip(files, results)).map { (file: $0.0, annotations: $0.1) }
        loading = false
    }

    private func fileSection(_ file: FileRecord, _ annotations: [PDFAnnotationInfo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(file.fileName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("打开 PDF") { model.open(fileId: file.id) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            ForEach(annotations) { annotation in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: annotation.colorHex))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(annotation.kind.displayName) · 第 \(annotation.page) 页")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if !annotation.quotedText.isEmpty {
                            Text(annotation.quotedText)
                                .font(.system(.callout, design: .serif))
                                .textSelection(.enabled)
                        }
                        if !annotation.comment.isEmpty {
                            Text(annotation.comment)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
