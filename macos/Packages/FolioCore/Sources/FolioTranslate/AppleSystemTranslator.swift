import Foundation
import Translation

/// Apple's on-device Translation framework, used as a pdf2zh_next
/// `--clitranslator` backend ("Apple 系统翻译（离线）").
///
/// pdf2zh_next's CLI translator protocol (pdf2zh_next/translator/translator_impl/clitranslator.py):
/// for every text segment it spawns the configured command (split with
/// `shlex`), writes the segment to stdin (UTF-8), closes stdin and reads the
/// translation from stdout (whitespace-trimmed). A non-zero exit status or a
/// timeout (`--clitranslator-timeout`, default 60 s) is retried 3 times with
/// exponential back-off; source/target languages are *not* passed, so the
/// command line must carry them (`--from en --to zh`). Segments are translated
/// concurrently (one process per segment, up to the pool size / QPS).
///
/// Works from a plain command-line process on macOS 26 as long as the language
/// pair is already installed (System Settings › General › Language & Region ›
/// Translation Languages). A CLI process cannot trigger the model download
/// (`TranslationSession.canRequestDownloads == false`); it fails with
/// `TranslationError.notInstalled`.
public enum AppleSystemTranslator {
    public enum Availability: String, Sendable, Hashable {
        /// Ready for offline use.
        case installed
        /// Supported, but the language models must be downloaded first.
        case needsDownload
        case unsupported
    }

    /// Machine-readable marker on stderr, recognised by `TranslationErrorClassifier`.
    public static let errorMarker = "FOLIO_APPLE_TRANSLATE:"

    /// Maps pdf2zh language codes (`zh`, `zh-CN`, `zh-TW`, `en`, `ja` …) to Apple's.
    public static func language(forCode code: String) -> Locale.Language {
        let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()
        switch normalized {
        case "zh", "zh-cn", "zh-hans", "zh-sg", "zh-hans-cn": return Locale.Language(identifier: "zh-Hans")
        case "zh-tw", "zh-hk", "zh-hant", "zh-mo", "zh-hant-tw": return Locale.Language(identifier: "zh-Hant")
        default: return Locale.Language(identifier: code.replacingOccurrences(of: "_", with: "-"))
        }
    }

    /// Translating from a command-line process with installed models needs macOS 26.
    public static var isSupportedOnThisSystem: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    public static func availability(from source: String, to target: String) async -> Availability {
        guard #available(macOS 26, *) else { return .unsupported }
        let status = await LanguageAvailability().status(from: language(forCode: source), to: language(forCode: target))
        switch status {
        case .installed: return .installed
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    public enum Failure: Error, LocalizedError, Sendable, Equatable {
        case notInstalled(String, String)
        case unsupported(String, String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled(let s, let t): String(localized: "Apple 系统翻译尚未下载 \(s) → \(t) 的语言模型。", bundle: .module)
            case .unsupported(let s, let t): String(localized: "Apple 系统翻译不支持 \(s) → \(t)。", bundle: .module)
            case .failed(let message): String(localized: "Apple 系统翻译失败：\(message)", bundle: .module)
            }
        }

        /// One-line diagnostic for stderr.
        var marker: String {
            switch self {
            case .notInstalled(let s, let t): "\(AppleSystemTranslator.errorMarker) not-installed \(s)->\(t)"
            case .unsupported(let s, let t): "\(AppleSystemTranslator.errorMarker) unsupported \(s)->\(t)"
            case .failed(let message): "\(AppleSystemTranslator.errorMarker) failed \(message)"
            }
        }
    }

    /// Translates `text` with installed models only (never downloads).
    public static func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let sourceLanguage = language(forCode: source), targetLanguage = language(forCode: target)
        switch await availability(from: source, to: target) {
        case .installed: break
        case .needsDownload: throw Failure.notInstalled(sourceLanguage.minimalIdentifier, targetLanguage.minimalIdentifier)
        case .unsupported: throw Failure.unsupported(sourceLanguage.minimalIdentifier, targetLanguage.minimalIdentifier)
        }
        guard #available(macOS 26, *) else {
            throw Failure.unsupported(sourceLanguage.minimalIdentifier, targetLanguage.minimalIdentifier)
        }
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        do {
            return try await session.translate(text).targetText
        } catch let error as TranslationError {
            throw Failure.failed(String(describing: error))
        }
    }

    // MARK: Command line

    public static let usage = """
    usage: folio-apple-translate --from <lang> --to <lang> [--check]
      Translates UTF-8 text from stdin to stdout with Apple's offline Translation framework
      (protocol of pdf2zh_next --clitranslator). Languages use pdf2zh codes: en, zh, zh-TW, ja …
      --check   print installed | needs-download | unsupported (exit 0 / 3 / 4)
    exit status: 0 ok, 1 translation error, 2 usage, 3 language models not installed, 4 unsupported pair
    """

    /// Entry point of `folio-apple-translate` (also usable from the app executable).
    public static func runCommandLine(arguments: [String], input: FileHandle = .standardInput,
                                      output: FileHandle = .standardOutput, errorOutput: FileHandle = .standardError) async -> Int32 {
        func fail(_ message: String, _ code: Int32) -> Int32 {
            try? errorOutput.write(contentsOf: Data((message + "\n").utf8))
            return code
        }
        var source: String?, target: String?, check = false
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--from", "-f": source = iterator.next()
            case "--to", "-t": target = iterator.next()
            case "--check": check = true
            case "--help", "-h":
                try? output.write(contentsOf: Data((usage + "\n").utf8))
                return 0
            default: return fail("unknown argument: \(argument)\n\(usage)", 2)
            }
        }
        guard let source, let target else { return fail(usage, 2) }

        let availability = await availability(from: source, to: target)
        if check {
            let text = availability == .needsDownload ? "needs-download" : availability.rawValue
            try? output.write(contentsOf: Data((text + "\n").utf8))
            return availability == .installed ? 0 : (availability == .needsDownload ? 3 : 4)
        }

        let data = (try? input.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 0 }
        do {
            let translated = try await translate(text, from: source, to: target)
            try? output.write(contentsOf: Data((translated + "\n").utf8))
            return 0
        } catch let failure as Failure {
            let code: Int32 = switch failure {
            case .notInstalled: 3
            case .unsupported: 4
            case .failed: 1
            }
            return fail(failure.marker + "\n" + (failure.errorDescription ?? ""), code)
        } catch {
            return fail("\(errorMarker) failed \(error)", 1)
        }
    }
}
