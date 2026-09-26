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
            toasts.show("没有可引用的条目", systemImage: "quote.opening")
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
                toasts.show(entries.count == 1 ? "已复制 \(style.title) 引用" : "已复制 \(entries.count) 条 \(style.title) 引用",
                            systemImage: "doc.on.clipboard")
            } catch {
                toasts.show("无法生成引用：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// Saves a .bib file for the selection or the current view (CITE-02).
    func exportBibTeX(itemIds: [String]? = nil) {
        let entries = citationEntries(itemIds)
        guard !entries.isEmpty else {
            toasts.show("没有可导出的条目", systemImage: "square.and.arrow.up")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText]
        panel.nameFieldStringValue = "\(title(for: sidebarSelection)).bib"
        panel.message = "导出 \(entries.count) 个条目的 BibTeX"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BibTeXWriter.document(entries).write(to: url, atomically: true, encoding: .utf8)
            toasts.show("已导出 \(entries.count) 个条目", systemImage: "checkmark.circle")
        } catch {
            toasts.show("导出失败：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
        }
    }
}
