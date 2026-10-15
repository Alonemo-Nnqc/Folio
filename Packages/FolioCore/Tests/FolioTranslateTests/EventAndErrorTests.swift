import Foundation
import Testing
@testable import FolioTranslate

@Suite struct DriverEventTests {
    @Test func parsesRealDriverLines() {
        // Lines captured from a real pdf2zh_next 2.9.0 run through the driver.
        let start = DriverEvent.parse(#"@@FOLIO@@{"type": "progress_start", "stage": "Parse PDF and Create Intermediate Representation", "stage_current": 0, "stage_total": 1, "stage_progress": 0.0, "overall_progress": 0.0, "part_index": 1, "total_parts": 1}"#)
        #expect(start?.kind == .progress(stage: "Parse PDF and Create Intermediate Representation", overall: 0, stageCurrent: 0, stageTotal: 1))

        let finish = DriverEvent.parse(#"@@FOLIO@@{"type": "finish", "mono": "/o/p.no_watermark.zh.mono.pdf", "dual": "/o/p.no_watermark.zh.dual.pdf", "glossary": null, "total_seconds": 8.8, "token_usage": {}}"#)
        #expect(finish?.kind == .finish(mono: "/o/p.no_watermark.zh.mono.pdf", dual: "/o/p.no_watermark.zh.dual.pdf", glossary: nil))

        let error = DriverEvent.parse(#"@@FOLIO@@{"type": "error", "error": "Translation subprocess initialization error: Connection error.", "error_type": "SubprocessError", "details": "Traceback…"}"#)
        #expect(error?.kind == .error(message: "Translation subprocess initialization error: Connection error.", type: "SubprocessError", details: "Traceback…"))

        #expect(DriverEvent.parse(#"@@FOLIO@@{"type": "stage", "stage": "starting"}"#)?.kind == .stage("starting"))
        #expect(DriverEvent.parse(#"@@FOLIO@@{"type": "version", "version": "2.9.0", "babeldoc": "0.6.2"}"#)?.kind == .version("2.9.0"))
        #expect(DriverEvent.parse(#"@@FOLIO@@{"type": "warmup_progress", "done": 3, "total": 40, "file": "SourceHanSerifCN-Regular.ttf"}"#)?.kind
                == .warmupProgress(done: 3, total: 40, file: "SourceHanSerifCN-Regular.ttf"))
    }

    @Test func ignoresLogLinesAndGarbage() {
        #expect(DriverEvent.parse("2026-10-11 11:17:10,773 INFO babeldoc: Found title paragraph") == nil)
        #expect(DriverEvent.parse("@@FOLIO@@{not json") == nil)
        #expect(DriverEvent.parse(#"@@FOLIO@@{"no_type": 1}"#) == nil)
    }

    @Test func stageNamesAreChinese() {
        #expect(TranslationStageNames.displayName(for: "Translate Paragraphs") == "翻译段落")
        #expect(TranslationStageNames.displayName(for: "Save PDF") == "保存 PDF")
        #expect(TranslationStageNames.displayName(for: "Something New") == "Something New")
    }

    @Test func progressTrackerIsMonotonicAndDeduplicates() {
        var tracker = ProgressTracker()
        #expect(tracker.stage("Parse Page Layout") == "分析页面版面")
        #expect(tracker.stage("Parse Page Layout") == nil)
        #expect(tracker.stage("") == nil)
        #expect(tracker.progress(0.10) == 0.10)
        #expect(tracker.progress(0.101) == nil)
        #expect(tracker.progress(0.05) == nil, "never goes backwards")
        #expect(tracker.progress(2) == 1)
        #expect(tracker.progress(1) == nil)
    }
}

@Suite struct ErrorClassifierTests {
    @Test func rateLimitFromRealGoogleError() {
        // Real failure: Google answered 429 (message only says RetryError, details carry the HTTP status).
        let failure = TranslationErrorClassifier.classify(
            message: "Translation subprocess initialization error: RetryError[<Future at 0x11b852ea0 state=finished raised HTTPError>]",
            details: "requests.exceptions.HTTPError: 429 Client Error: Too Many Requests for url: https://www.google.com/sorry/index")
        #expect(failure.reason == .quota)
        #expect(failure.message.contains("限流"))
    }

    @Test func networkFromRealConnectionError() {
        let failure = TranslationErrorClassifier.classify(message: "Translation subprocess initialization error: Connection error.")
        #expect(failure.reason == .network)
        #expect(failure.message.contains("网络"))
    }

    @Test func authentication() {
        let failure = TranslationErrorClassifier.classify(
            message: "Error code: 401 - {'error': {'message': 'Incorrect API key provided', 'code': 'invalid_api_key'}}")
        #expect(failure.reason == .authentication)
        #expect(failure.message.contains("API Key"))
        #expect(TranslationErrorClassifier.classify(message: "openai.AuthenticationError: invalid").reason == .authentication)
    }

    @Test func quotaVariants() {
        #expect(TranslationErrorClassifier.classify(message: "insufficient_quota: You exceeded your current quota").reason == .quota)
        #expect(TranslationErrorClassifier.classify(message: "Error code: 402 - Insufficient Balance").reason == .quota)
    }

    @Test func timestampsLineNumbersAndParameterNamesAreNotErrors() {
        let failure = TranslationErrorClassifier.classify(
            message: "Translation subprocess initialization error: RetryError[<Future raised CalledProcessError>]",
            logTail: ["2026-10-11 11:41:50,429 ERROR something", "  File \"x.py\", line 401, in do_translate",
                      "    translation = self.do_translate(text, rate_limit_params)", "returned non-zero exit status 3."])
        #expect(failure.reason == .unknown)
        #expect(TranslationErrorClassifier.classify(message: "openai.RateLimitError: Error code: 429").reason == .quota)
        #expect(TranslationErrorClassifier.classify(message: "HTTPError: 403 Client Error: Forbidden for url").reason == .authentication)
    }

    @Test func hexAddressesAreNotStatusCodes() {
        let failure = TranslationErrorClassifier.classify(message: "RetryError[<Future at 0x1429ab state=finished raised ValueError>]")
        #expect(failure.reason == .unknown)
        #expect(failure.message.hasPrefix("翻译失败："))
    }

    @Test func brokenEngineAndConfiguration() {
        #expect(TranslationErrorClassifier.classify(message: "ImportError: cannot import name 'BitStream' from 'bitstring'").reason == .engineBroken)
        #expect(TranslationErrorClassifier.classify(message: "ModuleNotFoundError: No module named 'babeldoc'").reason == .engineBroken)
        let config = TranslationErrorClassifier.classify(message: "Translation subprocess initialization error: DeepL Auth key is required")
        #expect(config.reason == .configuration)
    }

    /// One specific cause per failure, never a list of possibilities.
    @Test func specificMessages() {
        func message(_ text: String, details: String? = nil) -> String {
            TranslationErrorClassifier.classify(message: text, details: details).message
        }
        #expect(message("Error code: 401 - {'error': {'message': 'Incorrect API key provided'}}") == "API Key 无效（401），请在 设置 ▸ 翻译 中检查是否填写正确")
        #expect(message("HTTPError: 403 Client Error: Forbidden for url: https://api.x.com/v1").hasPrefix("翻译服务拒绝访问（403）"))
        #expect(message("Error code: 402 - Insufficient Balance").hasPrefix("翻译服务的账户余额或额度已用完（402）"))
        #expect(message("openai.RateLimitError: Error code: 429 - rate limit").hasPrefix("请求过于频繁，被翻译服务限流（429）"))
        let model = TranslationErrorClassifier.classify(
            message: "Error code: 404 - {'error': {'message': 'The model `gpt-6.1-sol` does not exist or you do not have access to it.', 'code': 'model_not_found'}}")
        #expect(model.reason == .modelNotFound && model.message.contains("gpt-6.1-sol"))
        #expect(message("Connection error.", details: "httpcore.ConnectError: [Errno 8] nodename nor servname provided, or not known (url https://api.example.org/v1)")
                == "找不到服务器 api.example.org，请检查 Base URL 是否正确")
        #expect(message("Connection error.", details: "HTTPConnectionPool(host='localhost', port=11434): Max retries exceeded (Caused by NewConnectionError: [Errno 61] Connection refused)")
                .hasPrefix("服务器 localhost 拒绝连接"))
        #expect(message("httpx.ReadTimeout: timed out", details: "url https://api.deepseek.com/chat") == "连接服务器 api.deepseek.com 超时，网络较慢或需要代理")
        #expect(TranslationErrorClassifier.classify(message: "Error code: 503 - Service Unavailable").reason == .serverError)
        #expect(message("Error code: 400 - {'error': {'message': 'temperature must be at most 1', 'type': 'invalid_request_error'}}")
                == "翻译服务不接受这次请求（400）：temperature must be at most 1")
        #expect(message("ModuleNotFoundError: No module named 'babeldoc'").contains("缺少 Python 模块 babeldoc"))
        #expect(message("OSError: [Errno 28] No space left on device") == "磁盘空间不足，无法保存译文")
        for reason in TranslationFailureReason.allCases {
            let text = TranslationErrorClassifier.text(for: reason, raw: "x", haystack: "x", original: "x")
            #expect(!text.contains("或没有权限") && !text.contains("或请求过于频繁"), "\(reason): one cause, not a list")
        }
    }

    @Test func appleTranslatorMarkerInLog() {
        let failure = TranslationErrorClassifier.classify(
            message: "Translation subprocess initialization error: RetryError[<Future raised CalledProcessError>]",
            logTail: ["ERROR CLI command failed (exit 3): FOLIO_APPLE_TRANSLATE: not-installed en->zh"])
        #expect(failure.reason == .appleTranslationUnavailable)
        #expect(failure.message.contains("翻译语言"))
    }
}
