import Foundation
import Testing
@testable import FolioTranslate

/// Real installation and translation. Network, ~1.3 GB of disk and minutes of time.
///
/// ```
/// FOLIO_LIVE=1 \
/// FOLIO_LIVE_DIR=/tmp/folio-translator \        # base directory (default: a new temp dir)
/// FOLIO_LIVE_PDF=/path/to/paper.pdf \           # copied before use (required for translation tests)
/// FOLIO_UV_CACHE=/path/to/uv-cache \            # optional: reuse a uv cache to save downloads
/// swift test --filter LiveTests
/// ```
/// Set `FOLIO_LIVE_REINSTALL=1` to force a fresh install into an existing `FOLIO_LIVE_DIR`,
/// `FOLIO_LIVE_NO_SYSTEM_UV=1` to exercise the uv download path.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FOLIO_LIVE"] == "1"))
struct LiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static let baseDirectory: URL = {
        if let dir = environment["FOLIO_LIVE_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.temporaryDirectory.appending(path: "FolioTranslatorLive-\(UUID().uuidString)")
    }()

    /// `FOLIO_LIVE_NO_SYSTEM_UV=1` ignores any uv on this Mac and downloads the official release.
    static var installation: TranslatorInstallation {
        TranslatorInstallation(baseDirectory: baseDirectory,
                               externalUVCache: environment["FOLIO_UV_CACHE"].map { URL(fileURLWithPath: $0) },
                               uvCandidates: environment["FOLIO_LIVE_NO_SYSTEM_UV"] == "1" ? [] : UVToolchain.defaultCandidates)
    }

    static func log(_ text: String) { print("LIVE: \(text)") }

    @Test func t1_install() async throws {
        let installation = Self.installation
        if case .installed = installation.status(), Self.environment["FOLIO_LIVE_REINSTALL"] != "1" {
            Self.log("already installed at \(Self.baseDirectory.path), skipping install")
            return
        }
        let phases = LockedValue<[TranslatorInstallPhase: Date]>([:])
        let fractions = LockedValue<[Double]>([])
        let start = Date()
        try await installation.install { progress in
            let first = phases.mutate { seen -> Bool in
                guard seen[progress.phase] == nil else { return false }
                seen[progress.phase] = Date()
                return true
            }
            fractions.mutate { $0.append(progress.fractionCompleted) }
            if first { Self.log(String(format: "%6.1fs phase %@ (%.0f%%) %@", Date().timeIntervalSince(start), progress.phase.rawValue,
                                       progress.fractionCompleted * 100, progress.detail ?? "")) }
        }
        let elapsed = Date().timeIntervalSince(start)
        let values = fractions.mutate { $0 }
        Self.log(String(format: "install finished in %.0fs, %d progress callbacks", elapsed, values.count))
        #expect(values == values.sorted(), "install progress is monotonic")
        #expect(values.last == 1)
        guard case .installed(let version, let executable) = installation.status() else {
            Issue.record("status after install: \(installation.status())")
            return
        }
        #expect(version == "2.9.0")
        Self.log("installed \(version) at \(executable.path); disk usage \(installation.diskUsage() / 1_000_000) MB")
        #expect(try await installation.verify() == "2.9.0")
        let assets = installation.layout.assetsDirectory
        let items = (try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []
        Self.log("assets in \(assets.path): \(items.sorted())")
        #expect(items.contains("models") && items.contains("fonts"))
        #expect(!FileManager.default.fileExists(atPath: installation.layout.cacheDirectory.path) || Self.environment["FOLIO_UV_CACHE"] != nil)
    }

    static func inputPDF() throws -> URL {
        guard let path = environment["FOLIO_LIVE_PDF"] else { throw LiveSkip.noPDF }
        let copy = baseDirectory.appending(path: "live-input/paper.pdf")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        return copy
    }

    enum LiveSkip: Error { case noPDF }

    func translate(service: String, appleCommand: [String]? = nil, options: TranslationOptions = TranslationOptions(pages: "1"))
        async throws -> (events: [TranslationEvent], seconds: Double, job: TranslationJob) {
        let runtime = try Self.installation.runtime()
        let output = Self.baseDirectory.appending(path: "live-output/\(service)")
        try? FileManager.default.removeItem(at: output)
        let request = TranslationRequest(input: try Self.inputPDF(), outputDirectory: output, serviceID: service, options: options)
        let job = TranslationJob(request: request, runtime: runtime, appleTranslatorCommand: appleCommand)
        let start = Date()
        var events: [TranslationEvent] = []
        for await event in job.start() {
            events.append(event)
            switch event {
            case .stage(let stage): Self.log(String(format: "[%@] %5.1fs stage %@", service, Date().timeIntervalSince(start), stage))
            case .progress: break
            default: Self.log("[\(service)] \(event)")
            }
        }
        let progress = events.compactMap { if case .progress(let p) = $0 { p } else { nil } }
        Self.log(String(format: "[%@] %.1fs, %d progress events %@", service, Date().timeIntervalSince(start), progress.count,
                        progress.map { String(format: "%.2f", $0) }.joined(separator: " ")))
        return (events, Date().timeIntervalSince(start), job)
    }

    @Test(arguments: ["siliconflowfree", "bing", "google"])
    func t2_translateFirstPage(service: String) async throws {
        let (events, _, job) = try await translate(service: service)
        let progress = events.compactMap { if case .progress(let p) = $0 { p } else { nil } }
        #expect(progress == progress.sorted())
        switch events.last {
        case .finished(let mono, let dual)?:
            let mono = try #require(mono), dual = try #require(dual)
            #expect(FileManager.default.fileExists(atPath: mono.path) && FileManager.default.fileExists(atPath: dual.path))
            #expect(progress.count >= 5 && progress.last == 1)
            Self.log("[\(service)] OK mono=\(mono.lastPathComponent) dual=\(dual.lastPathComponent)")
        case .failed(let message, let logURL)?:
            // Free services are rate limited; record the outcome instead of failing the suite.
            Self.log("[\(service)] FAILED: \(message) (log: \(logURL.path))")
            withKnownIssue("free service \(service) unavailable") { Issue.record("\(message)") }
        default:
            Issue.record("unexpected end: \(String(describing: events.last)); log \(job.logURL.path)")
        }
    }

    @Test func t3_cancelStopsEverything() async throws {
        let runtime = try Self.installation.runtime()
        let output = Self.baseDirectory.appending(path: "live-output/cancel")
        let request = TranslationRequest(input: try Self.inputPDF(), outputDirectory: output, serviceID: "bing",
                                         options: TranslationOptions(ignoreCache: true))
        let job = TranslationJob(request: request, runtime: runtime)
        var events: [TranslationEvent] = []
        var group: pid_t?
        let start = Date()
        var cancelledAt: Date?
        for await event in job.start() {
            events.append(event)
            group = group ?? job.processIdentifier
            if case .stage(let stage) = event, stage == "分析页面版面" || stage == "翻译段落", cancelledAt == nil {
                Self.log(String(format: "cancelling at %.1fs during %@", Date().timeIntervalSince(start), stage))
                cancelledAt = Date()
                job.cancel()
            }
        }
        #expect(events.last == .cancelled)
        if let cancelledAt { Self.log(String(format: "stream ended %.2fs after cancel", Date().timeIntervalSince(cancelledAt))) }
        let pgid = try #require(group)
        try await Task.sleep(for: .seconds(4))
        #expect(kill(-pgid, 0) == -1 && errno == ESRCH, "no process of the job's group survives")
    }

    @Test func t4_appleTranslatorThroughCLITranslator() async throws {
        // The built executable sits in the products directory, an ancestor of the test bundle.
        var helper: URL?
        if let path = Self.environment["FOLIO_APPLE_TRANSLATE"] { helper = URL(fileURLWithPath: path) }
        var ancestor = Bundle.module.bundleURL
        while helper == nil, ancestor.pathComponents.count > 2 {
            ancestor = ancestor.deletingLastPathComponent()
            let candidate = ancestor.appending(path: "folio-apple-translate")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { helper = candidate }
        }
        guard let helper else {
            Self.log("folio-apple-translate not found; run `swift build --product folio-apple-translate` first")
            return
        }
        let availability = await AppleSystemTranslator.availability(from: "en", to: "zh")
        Self.log("Apple Translation en→zh availability: \(availability)")
        let (events, seconds, job) = try await translate(service: "apple", appleCommand: [helper.path])
        Self.log(String(format: "[apple] ended after %.1fs: %@ (log %@)", seconds, String(describing: events.last), job.logURL.path))
        switch availability {
        case .installed:
            guard case .finished? = events.last else {
                Issue.record("Apple translation failed although models are installed")
                return
            }
        default:
            guard case .failed(let message, _)? = events.last else {
                Issue.record("expected failure without language models")
                return
            }
            #expect(message.contains("系统设置") || message.contains("不支持"))
        }
    }

    @Test func t5_downloadUV() async throws {
        let layout = TranslatorLayout(base: FileManager.default.temporaryDirectory.appending(path: "FolioUV-\(UUID().uuidString)"))
        defer { try? TranslatorInstallation.forceRemove(layout.base) }
        let start = Date()
        let uv = try await UVToolchain(layout: layout, candidates: []).download()
        Self.log(String(format: "downloaded uv %@ in %.1fs to %@", uv.version, Date().timeIntervalSince(start), uv.url.path))
        #expect(uv.version == UVToolchain.pinnedVersion)
        #expect(await UVToolchain(layout: layout, candidates: []).locate()?.url == layout.bundledUV)
    }

    @Test func t6_keychainRoundTrip() throws {
        let store = SecretStore(service: "com.nnqc.Folio.translation.tests")
        try store.set("sk-live-test", serviceID: "openai", option: "--openai-api-key")
        #expect(try store.get(serviceID: "openai", option: "--openai-api-key") == "sk-live-test")
        try store.set("sk-live-test-2", serviceID: "openai", option: "--openai-api-key")
        #expect(try store.secrets(for: TranslationServiceCatalog.service(id: "openai")!) == ["--openai-api-key": "sk-live-test-2"])
        try store.delete(serviceID: "openai", option: "--openai-api-key")
        #expect(try store.get(serviceID: "openai", option: "--openai-api-key") == nil)
    }
}
