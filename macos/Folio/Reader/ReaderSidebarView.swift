import AppKit
import PDFKit
import SwiftUI

/// What the sidebar asks the reader to do.
struct ReaderSidebarActions {
    /// A page, and the place on it when there is one (page space, the top-left corner of what is shown).
    var goToPage: (Int, CGPoint?) -> Void
    var showAnnotation: (ObjectIdentifier) -> Void
    var deleteAnnotation: (ObjectIdentifier) -> Void
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
            GeometryReader { proxy in
                ThumbnailStrip(pdfView: pdfView, width: proxy.size.width)
            }
        case .outline:
            if state.outline.isEmpty {
                ContentUnavailableView("没有目录", systemImage: "list.bullet.indent", description: Text("这份 PDF 没有内置目录"))
            } else {
                List(state.outline, children: \.children) { row in
                    Button {
                        if let page = row.pageIndex { actions.goToPage(page, row.point) }
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
                        .contextMenu {
                            Button("显示") { actions.showAnnotation(row.id) }
                            Button("删除批注", role: .destructive) { actions.deleteAnnotation(row.id) }
                        }
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
                if row.isOffPage {
                    // It can't be seen or reached on the page: said so, and it can be deleted from here.
                    Label("在页面范围之外，看不到；右键可删除", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
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

/// The pages, one under the other, as wide as the sidebar lets them be (in proportion to a page, room left for the
/// selection's outline and the page number).
private struct ThumbnailStrip: NSViewRepresentable {
    let pdfView: PDFView
    let width: CGFloat

    /// The cell for a page of the document's shape: a portrait page as before; a wide page (a side-by-side
    /// translation, slides) as wide as the sidebar allows and only as tall as it is, so the strip has no tall gaps.
    static func size(for width: CGFloat, aspect: CGFloat = 1.36) -> NSSize {
        if aspect < 1 {
            let w = min(max(width - 30, 110), 420).rounded()
            return NSSize(width: w, height: (w * aspect + 6).rounded())
        }
        let w = min(max(width - 52, 96), 300).rounded()
        return NSSize(width: w, height: (w * max(aspect, 1.0)).rounded())
    }

    /// Height over width of the document's pages (the most common shape among the first few).
    static func aspect(of document: PDFDocument?) -> CGFloat {
        guard let document, document.pageCount > 0 else { return 1.36 }
        let ratios = (0..<min(document.pageCount, 5)).compactMap { index -> CGFloat? in
            guard let page = document.page(at: index) else { return nil }
            let box = page.bounds(for: .cropBox)
            guard box.width > 1 else { return nil }
            let rotated = page.rotation % 180 != 0
            return rotated ? box.width / box.height : box.height / box.width
        }.sorted()
        guard !ratios.isEmpty else { return 1.36 }
        return min(max(ratios[ratios.count / 2], 0.3), 2)
    }

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = pdfView
        view.thumbnailSize = Self.size(for: width, aspect: Self.aspect(of: pdfView.document))
        view.backgroundColor = .clear
        view.allowsMultipleSelection = false
        view.setAccessibilityIdentifier("readerThumbnails")
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== pdfView { nsView.pdfView = pdfView }
        let size = Self.size(for: width, aspect: Self.aspect(of: pdfView.document))
        // Only for a real change: each change lays every thumbnail out again.
        if abs(nsView.thumbnailSize.width - size.width) >= 4 || abs(nsView.thumbnailSize.height - size.height) >= 4 {
            nsView.thumbnailSize = size
        }
    }
}

/// The reader's right panel: the paper's note, edited side by side with the PDF (NOTE-01).
struct ReaderNotesPanel: View {
    let model: AppModel
    let itemId: String
    var focusRequest: Int
    /// The document shown, chosen from the menu in the reader's toolbar above the panel.
    let choice: ItemDocumentChoice

    var body: some View {
        ItemDocumentsPanel(model: model, itemId: itemId, focusRequest: focusRequest, choice: choice, showsHeader: false, showsItemTitle: true)
            .id(itemId)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
