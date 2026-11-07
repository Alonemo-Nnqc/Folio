import AppKit
import FolioCitation
import FolioCore
import UniformTypeIdentifiers

extension AppModel {
    /// Items to cite: the given ids, else the selection, else the whole current view (CITE-02).
    func citationEntries(_ itemIds: [String]?) -> [CitationEntry] {
        let ids = itemIds ?? (selectedItemIDs.isEmpty ? rows : rows.filter(selectedItemIDs.contains))
        return ids.compactMap { snapshot.items[$0] }
            .filter { $0.kind == .regular }
            .map { CitationEntry(id: $0.id, citationKey: $0.citationKey ?? CitationKeyGenerator.baseKey(for: $0.metadata),
                                 metadata: $0.metadata) }
    }

    /// Copies formatted citations as plain text plus HTML (keeps italics when pasted into Word) (CITE-01).
    func copyCitations(style: CitationStyleOption, itemIds: [String]? = nil) {
        let entries = citationEntries(itemIds)
        guard !entries.isEmpty else {
            toasts.show(String(localized: "没有可引用的条目"), systemImage: "quote.opening")
            return
        }
        let service = citations
        Task {
            do {
                let output = try await service.render(entries, style: style.style)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(output.plainText, forType: .string)
                if let html = output.html { pasteboard.setString(html, forType: .html) }
                toasts.show(entries.count == 1 ? String(localized: "已复制 \(style.title) 引用") : String(localized: "已复制 \(entries.count) 条 \(style.title) 引用"),
                            systemImage: "doc.on.clipboard")
            } catch {
                toasts.show(String(localized: "无法生成引用：\(error.localizedDescription)"), systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// Saves the selection or the current view as BibTeX, RIS or CSL JSON (CITE-02, AI-06); the format
    /// is chosen in the save panel.
    func exportBibTeX(itemIds: [String]? = nil) {
        let entries = citationEntries(itemIds)
        guard !entries.isEmpty else {
            toasts.show(String(localized: "没有可导出的条目"), systemImage: "square.and.arrow.up")
            return
        }
        let panel = NSSavePanel()
        let formats = ReferenceFormat.allCases
        let remembered = ReferenceFormat(rawValue: UserDefaults.standard.string(forKey: "exportFormat") ?? "") ?? .bibtex
        let baseName = title(for: sidebarSelection)
        func apply(_ format: ReferenceFormat) {
            panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
            panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.displayName))
        popup.selectItem(at: formats.firstIndex(of: remembered) ?? 0)
        let changed = MenuAction { apply(formats[popup.indexOfSelectedItem]) }
        popup.target = changed
        popup.action = #selector(MenuAction.run)
        let label = NSTextField(labelWithString: String(localized: "格式："))
        let accessory = NSStackView(views: [label, popup])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        apply(remembered)
        panel.message = String(localized: "导出 \(entries.count) 个条目")
        let write = { [weak self] (response: NSApplication.ModalResponse) in
            _ = changed
            guard response == .OK, let url = panel.url else { return }
            let format = formats[popup.indexOfSelectedItem]
            UserDefaults.standard.set(format.rawValue, forKey: "exportFormat")
            do {
                try format.render(entries).write(to: url, atomically: true, encoding: .utf8)
                self?.toasts.show(String(localized: "已导出 \(entries.count) 个条目（\(format.displayName)）"), systemImage: "checkmark.circle")
            } catch {
                self?.toasts.show(String(localized: "导出失败：\(error.localizedDescription)"), systemImage: "exclamationmark.triangle")
            }
        }
        if let window = NSApp.keyWindow ?? libraryWindow { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }

    /// 文件 ▸ 导入 BibTeX / RIS… (AI-06): creates items, skipping works already in the library.
    func chooseReferencesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["bib", "ris", "json", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = String(localized: "导入")
        panel.message = String(localized: "选择 BibTeX（.bib）、RIS（.ris）或 CSL JSON 文件")
        let group = sidebarSelection.groupId
        present(panel) { [weak self] in
            guard let self else { return }
            let records = panel.urls.flatMap { url -> [ReferenceRecord] in
                (try? String(contentsOf: url, encoding: .utf8)).map(ReferenceReader.parse) ?? []
            }
            guard !records.isEmpty else {
                toasts.show(String(localized: "没有在文件中找到参考文献"), systemImage: "doc.questionmark")
                return
            }
            perform(String(localized: "导入失败")) {
                let result = try library.importReferences(records.map { ($0.metadata, $0.citationKey) }, toGroup: group)
                let duplicates = result.duplicates.isEmpty ? "" : String(localized: "，\(result.duplicates.count) 条已在库中")
                toasts.show(String(localized: "已导入 \(result.created.count) 条\(duplicates)"), systemImage: "square.and.arrow.down")
            }
        }
    }
}
