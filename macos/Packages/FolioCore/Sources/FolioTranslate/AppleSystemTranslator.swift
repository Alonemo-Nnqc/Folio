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
}
