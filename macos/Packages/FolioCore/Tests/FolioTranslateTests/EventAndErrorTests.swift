import Foundation
import Testing
@testable import FolioTranslate

@Suite struct ErrorClassifierTests {
    @Test func rateLimitFromRealGoogleError() {
        // Real failure: Google answered 429 (message only says RetryError, details carry the HTTP status).
        let failure = TranslationErrorClassifier.classify(
            message: "Translation subprocess initialization error: RetryError[<Future at 0x11b852ea0 state=finished raised HTTPError>]",
            details: "requests.exceptions.HTTPError: 429 Client Error: Too Many Requests for url: https://www.google.com/sorry/index")
        #expect(failure.reason == .quota)
        #expect(failure.message.contains("rate limit"))
    }

    @Test func networkFromRealConnectionError() {
        let failure = TranslationErrorClassifier.classify(message: "Translation subprocess initialization error: Connection error.")
        #expect(failure.reason == .network)
        #expect(failure.message.contains("network"))
    }

    @Test func authentication() {
        let failure = TranslationErrorClassifier.classify(
            message: "Error code: 401 - {'error': {'message': 'Incorrect API key provided', 'code': 'invalid_api_key'}}")
        #expect(failure.reason == .authentication)
        #expect(failure.message.contains("API key"))
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
        #expect(failure.message.hasPrefix("Translation failed: "))
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
        #expect(message("Error code: 401 - {'error': {'message': 'Incorrect API key provided'}}") == "The API key is invalid (401). Please check it in Settings ▸ Translation")
        #expect(message("HTTPError: 403 Client Error: Forbidden for url: https://api.x.com/v1").hasPrefix("The translation service denied access (403)"))
        #expect(message("Error code: 402 - Insufficient Balance").hasPrefix("The translation service account is out of balance or quota (402)"))
        #expect(message("openai.RateLimitError: Error code: 429 - rate limit").hasPrefix("Too many requests; the translation service is rate limiting (429)"))
        let model = TranslationErrorClassifier.classify(
            message: "Error code: 404 - {'error': {'message': 'The model `gpt-6.1-sol` does not exist or you do not have access to it.', 'code': 'model_not_found'}}")
        #expect(model.reason == .modelNotFound && model.message.contains("gpt-6.1-sol"))
        #expect(message("Connection error.", details: "httpcore.ConnectError: [Errno 8] nodename nor servname provided, or not known (url https://api.example.org/v1)")
                == "Server api.example.org not found. Please check that the Base URL is correct")
        #expect(message("Connection error.", details: "HTTPConnectionPool(host='localhost', port=11434): Max retries exceeded (Caused by NewConnectionError: [Errno 61] Connection refused)")
                .hasPrefix("The server localhost refused the connection"))
        #expect(message("httpx.ReadTimeout: timed out", details: "url https://api.deepseek.com/chat") == "Connecting to the server api.deepseek.com timed out; the network is slow or needs a proxy")
        #expect(TranslationErrorClassifier.classify(message: "Error code: 503 - Service Unavailable").reason == .serverError)
        #expect(message("Error code: 400 - {'error': {'message': 'temperature must be at most 1', 'type': 'invalid_request_error'}}")
                == "The translation service rejected this request (400): temperature must be at most 1")
        #expect(message("ModuleNotFoundError: No module named 'babeldoc'").contains("missing the Python module babeldoc"))
        #expect(message("OSError: [Errno 28] No space left on device") == "Not enough disk space to save the translation")
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
        #expect(failure.message.contains("Translation Languages"))
    }
}
