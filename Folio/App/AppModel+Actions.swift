import AppKit
import FolioCore
import UniformTypeIdentifiers

/// User-facing operations. Each one reports failures through a toast or alert instead of throwing.
extension AppModel {
    func perform(_ what: String = "操作失败", _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            toasts.show("\(what)：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
        }
    }

    // MARK: Groups

    func createGroup(parentId: String? = nil) {
        let siblings = parentId.map { snapshot.childGroups[$0] ?? [] } ?? snapshot.topLevelGroups
        let names = Set(siblings.compactMap { snapshot.groupsById[$0]?.name.lowercased() })
        var name = "未命名分组"
        var index = 2
        while names.contains(name.lowercased()) {
            name = "未命名分组 \(index)"
            index += 1
        }
        perform("无法创建分组") {
            let group = try library.createGroup(name: name, parentId: parentId)
            groupPendingRename = group.id
            sidebarSelection = .group(group.id)
        }
    }

    /// Returns false (and explains why) when the name is rejected so the editor can stay open.
    @discardableResult
    func renameGroup(_ id: String, to name: String) -> Bool {
        do {
            try library.renameGroup(id, to: name)
            return true
        } catch {
            NSSound.beep()
            toasts.show(error.localizedDescription, systemImage: "exclamationmark.triangle")
            return false
        }
    }

    func confirmDeleteGroup(_ id: String) {
        guard let group = snapshot.groupsById[id] else { return }
        let alert = NSAlert()
        alert.messageText = "删除分组「\(group.name)」？"
        let hasChildren = !(snapshot.childGroups[id] ?? []).isEmpty
        alert.informativeText = (hasChildren ? "其中的子分组也会一并删除。" : "")
            + "分组中的条目会保留在文库中；如需同时删除条目，请选择「同时将条目移到回收站」。"
        alert.addButton(withTitle: "删除分组")
        alert.addButton(withTitle: "同时将条目移到回收站")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        runAlert(alert) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.perform { try self.library.deleteGroup(id, trashItems: false) }
            case .alertSecondButtonReturn: self.perform { try self.library.deleteGroup(id, trashItems: true) }
            default: break
            }
        }
    }

    func moveGroup(_ id: String, toParent parentId: String?, index: Int) {
        perform("无法移动分组") { try library.moveGroup(id, toParent: parentId, index: index) }
    }

    // MARK: Membership

    func addItems(_ ids: [String], toGroup groupId: String) {
        guard let group = snapshot.groupsById[groupId], !ids.isEmpty else { return }
        perform("无法添加到分组") {
            let result = try library.addItems(ids, toGroup: groupId, includeSubgroups: settings.includeSubgroupItems)
            if result.added.isEmpty {
                toasts.show("「\(group.name)」中已有该条目", systemImage: "checkmark.circle")
            } else if !result.alreadyPresent.isEmpty {
                toasts.show("已添加 \(result.added.count) 项到「\(group.name)」，\(result.alreadyPresent.count) 项已存在",
                            systemImage: "folder.badge.plus")
            } else {
                toasts.show("已添加到「\(group.name)」", systemImage: "folder.badge.plus")
            }
        }
    }

    func removeFromCurrentGroup(_ ids: [String]) {
        guard let groupId = sidebarSelection.groupId else { return }
        perform { try library.removeItems(ids, fromGroup: groupId, includeSubgroups: settings.includeSubgroupItems) }
    }

    // MARK: Trash

    func trashItems(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        perform("无法删除") { try library.trashItems(ids) }
    }

    func trashFiles(_ fileIds: [String]) {
        guard !fileIds.isEmpty else { return }
        perform("无法删除文件") { try library.trashFiles(fileIds) }
    }

    func restoreItems(_ ids: [String]) {
        perform("无法恢复") { try library.restoreItems(ids) }
        toasts.show(ids.count == 1 ? "已恢复" : "已恢复 \(ids.count) 项", systemImage: "arrow.uturn.backward")
    }

    func confirmPurge(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = ids.count == 1 ? "彻底删除这一项？" : "彻底删除这 \(ids.count) 项？"
        alert.informativeText = "文件会从 Folio 文献库中彻底删除，此操作无法撤销。"
        alert.addButton(withTitle: "彻底删除")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        runAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.perform("无法删除") { try self.library.purgeItems(ids) }
        }
    }

    func confirmEmptyTrash() {
        let count = counts[.trash] ?? 0
        guard count > 0 else {
            toasts.show("回收站是空的", systemImage: "trash")
            return
        }
        let alert = NSAlert()
        alert.messageText = "清空回收站？"
        alert.informativeText = "回收站中的 \(count) 项会被彻底删除，此操作无法撤销。"
        alert.addButton(withTitle: "清空回收站")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        runAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.perform("无法清空回收站") { try self.library.emptyTrash() }
        }
    }

    /// Routes ⌫ / ⌘⌫ according to TRASH-02.
    func deleteSelection(command: Bool) {
        let items = Array(selectedItemIDs)
        let files = Array(selectedFileIDs)
        if sidebarSelection == .trash {
            confirmPurge(items)
            return
        }
        trashFiles(files)
        if isUserGroupSelected && !command {
            removeFromCurrentGroup(items)
        } else {
            trashItems(items)
        }
    }

    // MARK: Files

    func setDefaultFile(_ fileId: String) {
        perform { try library.setDefaultFile(fileId) }
    }

    /// Opens the default file of an item (LIST-08, OPEN-03), or its web page when it has no file.
    func open(itemId: String) {
        guard let item = snapshot.items[itemId] else { return }
        if let file = defaultFile(of: itemId) {
            FileOpener.open(fileURL(file), settings: settings)
            if item.kind == .regular && item.readStatus == .unread {
                perform { try library.updateItem(itemId) { $0.readStatus = .reading } }
            }
        } else if let url = webURL(for: item) {
            FileOpener.open(web: url)
        }
    }

    func open(fileId: String) {
        guard let file = snapshot.files[fileId] else { return }
        FileOpener.open(fileURL(file), settings: settings)
        if let item = snapshot.items[file.itemId], item.kind == .regular, item.readStatus == .unread {
            perform { try library.updateItem(item.id) { $0.readStatus = .reading } }
        }
    }

    func webURL(for item: Item) -> URL? {
        if let doi = item.doi, !doi.isEmpty { return URL(string: "https://doi.org/\(doi)") }
        if let url = item.url, let parsed = URL(string: url), parsed.scheme != nil { return parsed }
        if let arxiv = item.arxivId, !arxiv.isEmpty { return URL(string: "https://arxiv.org/abs/\(arxiv)") }
        return nil
    }

    func revealInFinder(itemIds: [String], fileIds: [String]) {
        var urls = fileIds.compactMap { snapshot.files[$0] }.map(fileURL)
        urls += itemIds.compactMap(defaultFile(of:)).map(fileURL)
        if urls.isEmpty { urls = [library.root] }
        FileOpener.reveal(urls)
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "添加"
        panel.message = "选择要添加到 Folio 的文献"
        guard panel.runModal() == .OK else { return }
        importer.importFiles(panel.urls, toGroup: sidebarSelection.groupId)
    }

    func chooseFilesToAttach(to itemId: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择要添加到该条目的文件"
        guard panel.runModal() == .OK else { return }
        importer.attachFiles(panel.urls, to: itemId)
    }

    // MARK: Tags, rating, read status

    func toggleTag(_ tagId: String, on ids: [String]) {
        let allTagged = ids.allSatisfy { snapshot.itemTags[$0]?.contains(tagId) ?? false }
        perform { try library.setTag(tagId, onItems: ids, enabled: !allTagged) }
    }

    func setTag(_ tagId: String, on ids: [String], enabled: Bool) {
        perform { try library.setTag(tagId, onItems: ids, enabled: enabled) }
    }

    func confirmDeleteTag(_ tagId: String) {
        guard let tag = snapshot.tagsById[tagId] else { return }
        let count = snapshot.tagItems[tagId]?.count ?? 0
        let alert = NSAlert()
        alert.messageText = "删除标签「\(tag.name)」？"
        alert.informativeText = count > 0 ? "该标签会从 \(count) 个条目中移除。" : "目前没有条目使用该标签。"
        alert.addButton(withTitle: "删除标签")
        alert.addButton(withTitle: "取消")
        alert.buttons[0].hasDestructiveAction = true
        runAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.perform("无法删除标签") { try self.library.deleteTag(tagId) }
        }
    }

    func setReadStatus(_ status: ReadStatus, on ids: [String]) {
        perform {
            for id in ids where snapshot.items[id]?.kind == .regular {
                try library.updateItem(id) { $0.readStatus = status }
            }
        }
    }

    func setRating(_ rating: Int, on ids: [String]) {
        perform {
            for id in ids { try library.updateItem(id) { $0.rating = rating } }
        }
    }

    // MARK: Ordering

    func moveItems(_ ids: [String], toIndex index: Int) {
        guard !search.isActive else { return }
        perform { try library.moveItems(ids, inScope: sidebarSelection, displayedOrder: rows, toIndex: index) }
    }

    func setSort(_ sort: SortState) {
        perform { try library.setSort(sort, forScope: sidebarSelection) }
    }

    // MARK: Search

    func showSearch() {
        search.isVisible = true
        searchFocusRequest += 1
    }

    // MARK: Alerts

    func runAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
