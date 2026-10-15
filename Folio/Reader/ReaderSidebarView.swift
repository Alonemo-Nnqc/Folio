import AppKit
import PDFKit
import SwiftUI

/// What the sidebar asks the reader to do.
struct ReaderSidebarActions {
    var goToPage: (Int) -> Void
    var showAnnotation: (ObjectIdentifier) -> Void
    var showHit: (Int) -> Void
}

/// Reader sidebar: thumbnails, table of contents, annotations and find results (READER-02/03).
struct ReaderSidebarView: View {
    @Bindable var state: ReaderState
    let pdfView: PDFView
    let actions: ReaderSidebarActions

    var body: some View {
        VStack(spacing: 0) {
            Picker("边栏", selection: $state.sidebarTab) {
                ForEach(ReaderSidebarTab.allCases, id: \.self) { tab in
                    Image(systemName: tab.symbol)
                        .help(tab.title)
                        .accessibilityLabel(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityIdentifier("readerSidebarTabs")
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.sidebarTab {
        case .thumbnails:
            ThumbnailStrip(pdfView: pdfView)
        case .outline:
            if state.outline.isEmpty {
                ContentUnavailableView("没有目录", systemImage: "list.bullet.indent", description: Text("这份 PDF 没有内置目录"))
            } else {
                List(state.outline, children: \.children) { row in
                    Button {
                        if let page = row.pageIndex { actions.goToPage(page) }
                    } label: {
                        HStack {
                            Text(row.title).lineLimit(2)
                            Spacer()
                            if let page = row.pageIndex {
                                Text("\(page + 1)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        case .annotations:
            if state.annotations.isEmpty {
                ContentUnavailableView("没有批注", systemImage: "highlighter",
                                       description: Text("用工具栏上的高亮、下划线、便签等工具添加批注"))
            } else {
                List(state.annotations) { row in
                    Button { actions.showAnnotation(row.id) } label: { AnnotationRowView(row: row) }
                        .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        case .search:
            if state.isSearching && state.searchHits.isEmpty {
                ProgressView().frame(maxHeight: .infinity)
            } else if state.searchHits.isEmpty {
                ContentUnavailableView(state.searchQuery.isEmpty ? String(localized: "在文档中查找") : String(localized: "没有找到「\(state.searchQuery)」"),
                                       systemImage: "magnifyingglass",
                                       description: Text(state.searchQuery.isEmpty ? String(localized: "在工具栏的搜索框中输入文字（⌘F）") : ""))
            } else {
                List(state.searchHits) { hit in
                    Button { actions.showHit(hit.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("第 \(hit.pageLabel) 页").font(.caption).foregroundStyle(.secondary)
                            Text(hit.context).lineLimit(3)
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(state.currentHit == hit.id ? Color.accentColor.opacity(0.18) : nil)
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom) {
                    Text("\(state.searchHits.count) 个结果")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
        }
    }
}

private struct AnnotationRowView: View {
    let row: AnnotationRow

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: row.color.withAlphaComponent(1)))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(row.kind) · 第 \(row.pageIndex + 1) 页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !row.text.isEmpty {
                    Text(row.text).font(.callout).lineLimit(4)
                }
                if !row.comment.isEmpty {
                    Text(row.comment).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ThumbnailStrip: NSViewRepresentable {
    let pdfView: PDFView

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.thumbnailSize = NSSize(width: 110, height: 150)
        view.backgroundColor = .clear
        view.allowsMultipleSelection = false
        view.setAccessibilityIdentifier("readerThumbnails")
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== pdfView { nsView.pdfView = pdfView }
    }
}

/// The reader's right panel: the paper's note, edited side by side with the PDF (NOTE-01).
struct ReaderNotesPanel: View {
    let model: AppModel
    let itemId: String
    var focusRequest: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("笔记")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
            if let title = model.snapshot.items[itemId]?.title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
            }
            Divider().padding(.top, 4)
            NoteEditor(model: model, itemId: itemId, focusRequest: focusRequest)
                .padding(.horizontal, 6)
        }
    }
}
