import AppKit
import PDFKit
import FolioCore

/// `-FolioTranslateSelfTest <log>` with `-FolioPreviewSelect <title>`: translates page 1 of that item's PDF
/// through the real coordinator (service from `-FolioTranslateService`, default bing) and checks the result
/// is filed under the item. Needs an installed engine (`-FolioTranslatorDirectory`).
enum TranslationSelfTest {
    static func run(model: AppModel, itemId: String, log: String) {
        Task { @MainActor in
            @MainActor func write(_ line: String) { SimulatedDrop.append(line + "\n", to: log) }
            guard let file = model.defaultFile(of: itemId) else { return write("FAIL no file") }
            model.settings.translationService = UserDefaults.standard.string(forKey: "FolioTranslateService") ?? "bing"
            model.settings.translationOptions.pages = UserDefaults.standard.string(forKey: "FolioTranslatePages") ?? "1"
            model.settings.translationOptions.outputs = .both
            write("engine: native")
            let started = Date()
            model.translations.start(fileId: file.id)
            // Apple system translation first checks its language packs, so the job appears a moment later.
            while model.translations.jobs[itemId] == nil, Date().timeIntervalSince(started) < 10 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            var lastStage = ""
            var previews: Set<URL> = []
            while model.translations.jobs[itemId] != nil {
                if let job = model.translations.jobs[itemId] {
                    let line = "\(job.stage) \(job.fraction.map { "\(Int($0 * 100))%" } ?? "")"
                    if line != lastStage { write(String(format: "%5.1fs ", Date().timeIntervalSince(started)) + line); lastStage = line }
                    if let preview = job.preview, previews.insert(preview).inserted {
                        write(String(format: "%5.1fs preview %@ (%d pages)", Date().timeIntervalSince(started), preview.lastPathComponent,
                                     PDFDocument(url: preview)?.pageCount ?? 0))
                        // 对照阅读 follows the translation in an open reader.
                        if let reader = NSApp.windows.compactMap({ $0.windowController as? ReaderWindowController }).first,
                           !reader.isShowingParallel {
                            reader.toggleParallelReading(nil)
                            write("reader shows the preview: \(reader.isShowingParallel)")
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(300))
                if Date().timeIntervalSince(started) > 600 { return write("FAIL timeout") }
            }
            try? await Task.sleep(for: .seconds(1))
            let translations = model.snapshot.files(of: itemId).filter { $0.translationOf == file.id }
            write((translations.count == 2 ? "PASS" : "FAIL") + " translations filed: " + translations.map(\.fileName).joined(separator: " | "))
            write((translations.allSatisfy { FileManager.default.fileExists(atPath: model.fileURL($0).path) } ? "PASS" : "FAIL") + " files exist")
            write(String(format: "DONE in %.0fs", Date().timeIntervalSince(started)))
        }
    }
}
