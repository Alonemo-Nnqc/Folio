import FolioCore
import SwiftUI

/// Editable metadata of a regular item, laid out after the reference design (INSP-02).
struct MetadataInspector: View {
    let model: AppModel
    let item: Item
    @State private var showTagPicker = false
    @State private var abstractExpanded = true
    @State private var moreFields = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                citationSection
                librarySection
                if let abstract = item.abstract, !abstract.isEmpty { abstractSection(abstract) }
                filesSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    private func update(_ change: @escaping (inout Item) -> Void) {
        // Author, year or title typed by hand rename the files, like retrieved metadata does (when 自动重命名 is on).
        model.perform(String(localized: "无法保存")) { try model.library.updateItem(item.id, autoRename: model.settings.autoRenameFiles, change) }
    }

    // MARK: Header: type, title, authors, key

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Menu {
                ForEach(ItemType.allCases, id: \.self) { type in
                    Button(type.displayName) { update { $0.type = type } }
                }
            } label: {
                Text(item.type.displayName)
                    .font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("文献类型")

            TextField("标题", text: $titleDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.title3, design: .serif).weight(.bold))
                .focused($titleFocused)
                .onAppear { titleDraft = item.title }
                .onChange(of: item.title) { _, value in if !titleFocused { titleDraft = value } }
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                .onSubmit(commitTitle)
                .accessibilityIdentifier("inspectorTitle")

            AuthorsEditor(authors: item.authors) { authors in update { $0.authors = authors } }

            if let key = item.citationKey, !key.isEmpty {
                Text(key)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 4)
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { titleDraft = item.title; return }
        if trimmed != item.title { update { $0.title = trimmed } }
    }

    // MARK: Citation fields

    private var citationSection: some View {
        InspectorSection(title: String(localized: "引用")) {
            EditableField(label: String(localized: "年份"), value: item.year.map(String.init)) { value in
                update { $0.year = Int(value) }
            }
            // The fields of this type of work, named for it ("期刊", "所属图书", "授予单位"…), and any other with a value (#19).
            ForEach(ItemField.shown(for: item.metadata), id: \.self) { field in
                fieldRow(field)
                if field == .source { JournalMetricsRow(model: model, item: item) }
            }
            // The rest, folded away: not usual for this type, but there to fill in.
            let others = ItemField.allCases.filter { !ItemField.shown(for: item.metadata).contains($0) }
            if !others.isEmpty {
                DisclosureGroup("更多字段", isExpanded: $moreFields) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(others, id: \.self) { fieldRow($0) }
                    }
                    .padding(.top, 4)
                }
                .font(.callout)
            }
            EditableField(label: String(localized: "引用键"), value: item.citationKey, monospaced: true) { value in
                update { $0.citationKey = value.nilIfEmpty }
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: ItemField) -> some View {
        let value = field.text(in: item.metadata)
        switch field {
        case .doi:
            EditableField(label: "DOI", value: value, monospaced: true,
                          link: value.flatMap { $0.isEmpty ? nil : URL(string: "https://doi.org/\($0)") }) { text in set(field, text) }
        case .arxivId:
            EditableField(label: "arXiv", value: value, monospaced: true,
                          link: value.flatMap { $0.isEmpty ? nil : URL(string: "https://arxiv.org/abs/\($0)") }) { text in set(field, text) }
        case .isbn:
            EditableField(label: "ISBN", value: value, monospaced: true) { text in set(field, text) }
        case .url:
            EditableField(label: "URL", value: value, link: value.flatMap(URL.init(string:))) { text in set(field, text) }
        case .editors, .translators:
            EditableField(label: field.label(for: item.type), value: value, placeholder: String(localized: "姓, 名; 姓, 名")) { text in set(field, text) }
        case .genre:
            EditableField(label: field.label(for: item.type), value: value,
                          placeholder: item.type == .thesis ? String(localized: "博士学位论文") : "—") { text in set(field, text) }
        default:
            EditableField(label: field.label(for: item.type), value: value) { text in set(field, text) }
        }
    }

    private func set(_ field: ItemField, _ text: String) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines) != (field.text(in: item.metadata) ?? "") else { return }
        update { item in
            var metadata = item.metadata
            field.set(text, in: &metadata)
            item.metadata = metadata
        }
    }

    // MARK: Library: rating, status, groups, tags

    private var librarySection: some View {
        InspectorSection(title: String(localized: "文库")) {
            row(String(localized: "评分")) {
                RatingControl(rating: item.rating) { value in model.setRating(value, on: [item.id]) }
            }
            row(String(localized: "状态")) {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("阅读状态", selection: Binding(get: { item.readStatus },
                                                         set: { model.setReadStatus($0, on: [item.id]) })) {
                        ForEach(ReadStatus.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    if item.readStatus == .reading, let progress = model.readingProgress[item.id], let pages = progress.pageCount {
                        HStack(spacing: 5) {
                            Image(nsImage: ReadingRing.image(.reading, fraction: progress.fraction, size: 13)).accessibilityHidden(true)
                            Text("读到第 \(progress.pageIndex + 1) / \(pages) 页")
                            .help(model.snapshot.files[progress.fileId].map { model.label(of: $0) } ?? "")
                        if let file = model.snapshot.files[progress.fileId], model.snapshot.files(of: item.id).filter(\.isPDF).count > 1 {
                            Text(model.label(of: file)).lineLimit(1).truncationMode(.middle)
                        }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            row(String(localized: "分组")) {
                FlowLayout(spacing: 6) {
                    ForEach(groups, id: \.id) { group in
                        GroupChip(name: group.name, colorHex: group.colorHex) {
                            model.perform { try model.library.removeItems([item.id], fromGroup: group.id, includeSubgroups: false) }
                        }
                    }
                    Menu {
                        ForEach(model.groupsForMenus, id: \.group.id) { entry in
                            Button(String(repeating: "    ", count: entry.depth) + entry.group.name) {
                                model.addItems([item.id], toGroup: entry.group.id)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(model.groupsForMenus.isEmpty)
                    .help("添加到分组")
                }
            }
            row(String(localized: "标签")) {
                FlowLayout(spacing: 6) {
                    ForEach(model.snapshot.tags(of: item.id)) { tag in
                        TagChip(tag: tag) { model.setTag(tag.id, on: [item.id], enabled: false) }
                    }
                    Button {
                        showTagPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("添加标签")
                    .accessibilityIdentifier("addTagButton")
                    .popover(isPresented: $showTagPicker, arrowEdge: .bottom) {
                        TagPickerPopover(model: model, itemIds: [item.id])
                    }
                }
            }
        }
    }

    private var groups: [LibraryGroup] {
        (model.snapshot.itemGroups[item.id] ?? []).compactMap { model.snapshot.groupsById[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    // MARK: Abstract

    private func abstractSection(_ abstract: String) -> some View {
        InspectorSection(title: String(localized: "内容")) {
            DisclosureGroup("摘要", isExpanded: $abstractExpanded) {
                Text(abstract)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.callout.weight(.semibold))
        }
    }

    // MARK: Files and dates

    private var filesSection: some View {
        InspectorSection(title: String(localized: "文件")) {
            let files = model.snapshot.files(of: item.id)
            if files.isEmpty {
                Button("添加文件…", systemImage: "paperclip") { model.chooseFilesToAttach(to: item.id) }
                    .buttonStyle(.borderless)
            }
            ForEach(files) { file in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: model.fileURL(file).path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(model.label(of: file))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.fileName)
                    if file.id == item.defaultFileId {
                        DefaultFileBadge()
                    }
                    Spacer()
                }
                .font(.callout)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.open(fileId: file.id) }
                .contextMenu {
                    Button("打开") { model.open(fileId: file.id) }
                    Button("设为默认打开文件") { model.setDefaultFile(file.id) }
                        .disabled(file.id == item.defaultFileId)
                    Button("在 Finder 中显示") { model.revealInFinder(itemIds: [], fileIds: [file.id]) }
                }
            }
            Text("添加于 \(item.dateAdded.formatted(date: .abbreviated, time: .shortened)) · 修改于 \(item.dateModified.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }
}

struct GroupChip: View {
    let name: String
    var colorHex: String?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .foregroundStyle(colorHex.map { Color(hex: $0) } ?? Color.accentColor)
            Text(name).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("从该分组移除")
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

/// Wraps chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
