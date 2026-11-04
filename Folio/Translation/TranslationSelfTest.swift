import AppKit
import PDFKit
import FolioCore

/// `-FolioTranslateSelfTest <log>` with `-FolioPreviewSelect <title>`: translates page 1 of that item's PDF
/// through the real coordinator (service from `-FolioTranslateService`, default bing) and checks the result
/// is filed under the item. Needs an installed engine (`-FolioTranslatorDirectory`).
enum TranslationSelfTest {
    /// The determinate progress bars showing, by the kind of window they are in, with where they are in it.
    private static func progressBars() -> [(kind: String, value: Double, frame: CGRect)] {
        func find(in view: NSView) -> NSProgressIndicator? {
            if let bar = view as? NSProgressIndicator, !bar.isHidden, !bar.isIndeterminate { return bar }
            for subview in view.subviews { if let bar = find(in: subview) { return bar } }
            return nil
        }
        return NSApp.windows.compactMap { window in
            let kind = window.windowController is ReaderWindowController ? "reader" : window.windowController is FolioWindowController ? "list" : nil
            guard let kind, window.isVisible, let content = window.contentView, let bar = find(in: content) else { return nil }
            return (kind, bar.doubleValue, bar.convert(bar.bounds, to: nil))
        }
    }

    static func run(model: AppModel, itemId: String, log: String) {
        Task { @MainActor in
            @MainActor func write(_ line: String) { SimulatedDrop.append(line + "\n", to: log) }
            guard let file = model.defaultFile(of: itemId) else { return write("FAIL no file") }
            // The settings are the user's: as they were afterwards.
            let service = model.settings.translationService, options = model.settings.translationOptions
            defer {
                model.settings.translationService = service
                model.settings.translationOptions = options
            }
            model.settings.translationService = UserDefaults.standard.string(forKey: "FolioTranslateService") ?? "bing"
            model.settings.translationOptions.pages = UserDefaults.standard.string(forKey: "FolioTranslatePages") ?? "1"
            model.settings.translationOptions.outputs = .both
            model.settings.translationOptions.ignoreCache = UserDefaults.standard.bool(forKey: "FolioTranslateFresh")
            write("engine: native")
            let started = Date()
            model.translations.start(fileId: file.id)
            // Apple system translation first checks its language packs, so the job appears a moment later.
            while model.translations.jobs[itemId] == nil, Date().timeIntervalSince(started) < 10 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            var lastStage = ""
            var previews: Set<URL> = []
            // What the bars show as it runs, and whether they stay where they are while the numbers change.
            var barValues: [String: Set<Int>] = [:]
            var barPlaces: [String: Set<String>] = [:]
            while model.translations.jobs[itemId] != nil {
                for bar in progressBars() {
                    barValues[bar.kind, default: []].insert(Int(bar.value * 100))
                    let f = bar.frame
                    barPlaces[bar.kind, default: []].insert(String(format: "x %.1f width %.1f", f.minX, f.width))
                }
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
            for (kind, values) in barValues.sorted(by: { $0.key < $1.key }) {
                write((values.count >= 3 ? "PASS" : "FAIL") + " \(kind) bar followed the progress: \(values.count) values, \(values.min() ?? 0)…\(values.max() ?? 0)%")
                let places = barPlaces[kind] ?? []
                write((places.count == 1 ? "PASS" : "FAIL") + " \(kind) bar stayed in place: \(places.count) positions \(places.sorted().prefix(6))")
            }
            write(String(format: "DONE in %.0fs", Date().timeIntervalSince(started)))
        }
    }
}
