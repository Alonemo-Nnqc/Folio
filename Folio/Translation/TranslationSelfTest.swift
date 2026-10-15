import AppKit
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
            model.settings.translationOptions.pages = "1"
            model.settings.translationOptions.outputs = .both
            write("engine: \(model.translations.engineStatus)")
            let started = Date()
            model.translations.start(fileId: file.id)
            // Apple system translation first checks its language packs, so the job appears a moment later.
            while model.translations.jobs[itemId] == nil, Date().timeIntervalSince(started) < 10 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            var lastStage = ""
            while model.translations.jobs[itemId] != nil {
                if let job = model.translations.jobs[itemId] {
                    let line = "\(job.stage) \(job.fraction.map { "\(Int($0 * 100))%" } ?? "")"
                    if line != lastStage { write(String(format: "%5.1fs ", Date().timeIntervalSince(started)) + line); lastStage = line }
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
