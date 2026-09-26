import AppKit

/// Asks the questions that come up during imports, one sheet at a time (DUP-02/03).
final class DuplicatePrompter {
    enum DuplicateChoice { case attach, discard }

    private var chain: Task<Void, Never>?
    private var rememberedChoice: DuplicateChoice?
    private var pending = 0

    /// "已有该条目" — attach the new file to the existing item or discard it.
    func askDuplicateItem(title: String, completion: @escaping (DuplicateChoice) -> Void) {
        enqueue { [weak self] in
            if let remembered = self?.rememberedChoice { return completion(remembered) }
            let alert = NSAlert()
            alert.messageText = "已有该条目「\(title)」"
            alert.informativeText = "库中已有同一篇文献。要把新添加的文件作为附件放到这个条目下吗？"
            alert.addButton(withTitle: "作为附件添加到该条目")
            alert.addButton(withTitle: "放弃")
            if (self?.pending ?? 0) > 1 {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "对其余项执行相同操作"
            }
            let response = await Self.present(alert)
            let choice: DuplicateChoice = response == .alertFirstButtonReturn ? .attach : .discard
            if alert.suppressionButton?.state == .on { self?.rememberedChoice = choice }
            completion(choice)
        }
    }

    /// "回收站中已有该文献" — restore it?
    func askRestore(title: String, completion: @escaping (Bool) -> Void) {
        enqueue {
            let alert = NSAlert()
            alert.messageText = "回收站中已有该文献，是否恢复？"
            alert.informativeText = "「\(title)」"
            alert.addButton(withTitle: "恢复")
            alert.addButton(withTitle: "取消")
            completion(await Self.present(alert) == .alertFirstButtonReturn)
        }
    }

    private func enqueue(_ work: @escaping () async -> Void) {
        pending += 1
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await work()
            guard let self else { return }
            self.pending -= 1
            if self.pending == 0 { self.rememberedChoice = nil }
        }
    }

    private static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
            return alert.runModal()
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
