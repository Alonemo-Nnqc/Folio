import Foundation
import Testing
@testable import FolioTranslate

@Suite struct ChildProcessTests {
    @Test func explicitEnvironmentAndDirectory() async throws {
        let temp = TemporaryDirectory()
        let spec = ProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"),
                               arguments: ["-c", "pwd; echo \"FOO=$FOO PATH=$PATH\"; echo oops >&2; exit 7"],
                               environment: ["FOO": "bar", "PATH": "/usr/bin:/bin"], currentDirectory: temp.url)
        let result = try await ChildProcess.run(spec)
        #expect(result.termination == .exited(7))
        let stdout = result.lines.filter { $0.stream == .stdout }.map(\.text)
        #expect(stdout.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == temp.url.resolvingSymlinksInPath())
        #expect(stdout.dropFirst().first == "FOO=bar PATH=/usr/bin:/bin")
        #expect(result.lines.contains(ProcessOutputLine(stream: .stderr, text: "oops")))
    }

    @Test func launchFailureThrows() {
        let spec = ProcessSpec(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], environment: [:],
                               currentDirectory: URL(fileURLWithPath: "/"))
        #expect(throws: ProcessLaunchError.self) { try ChildProcess.launch(spec) }
    }

    @Test func strayWorkerIsClearedAfterLeaderExits() async throws {
        let temp = TemporaryDirectory()
        let pidFile = temp.url.appending(path: "stray.pid")
        // The leader exits at once; its worker keeps stdout open.
        let spec = ProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"),
                               arguments: ["-c", "\(termIgnoringWorker(pidFile: pidFile)); echo leader-done"],
                               environment: ["PATH": "/usr/bin:/bin"], currentDirectory: temp.url)
        let start = Date()
        let result = try await ChildProcess.run(spec)
        #expect(result.termination == .exited(0))
        #expect(result.lines.map(\.text) == ["leader-done"])
        #expect(Date().timeIntervalSince(start) < 10)
        let worker = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(!isAlive(worker))
    }

    @Test func terminateGroupKillsGrandchildren() async throws {
        let temp = TemporaryDirectory()
        let pidFile = temp.url.appending(path: "child.pid")
        // The shell starts a background grandchild (ignoring SIGTERM) and waits.
        let spec = ProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"),
                               arguments: ["-c", "\(termIgnoringWorker(pidFile: pidFile)); echo started; wait"],
                               environment: ["PATH": "/usr/bin:/bin"], currentDirectory: temp.url)
        let process = try ChildProcess.launch(spec)
        #expect(getpgid(process.pid) == process.pid, "runs in its own process group")
        var iterator = process.output.makeAsyncIterator()
        #expect(await iterator.next()?.text == "started")
        let grandchild = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(isAlive(grandchild))

        process.terminateGroup(grace: 1)
        let termination = await process.waitUntilExit()
        #expect(termination == .signaled(SIGTERM))
        // The grandchild ignores SIGTERM and must be killed by the delayed SIGKILL.
        try await Task.sleep(for: .milliseconds(300))
        #expect(isAlive(grandchild), "still alive during the grace period")
        for _ in 0..<40 where isAlive(grandchild) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!isAlive(grandchild))
    }
}

@Suite struct TranslationJobTests {
    /// A fake "python" that ignores the driver script and prints driver events.
    static let fakeEngine = #"""
    # args: -u <driver.py> translate <pdf2zh args...>
    out=""; prev=""
    for a in "$@"; do
      if [ "$prev" = "--output" ]; then out="$a"; fi
      prev="$a"; last="$a"
    done
    stem=$(basename "$last" .pdf)
    echo '@@FOLIO@@{"type": "stage", "stage": "starting"}'
    echo 'some log line' >&2
    echo '@@FOLIO@@{"type": "progress_start", "stage": "Parse PDF and Create Intermediate Representation", "overall_progress": 0.0}'
    echo '@@FOLIO@@{"type": "progress_update", "stage": "Translate Paragraphs", "overall_progress": 40.0}'
    echo '@@FOLIO@@{"type": "progress_update", "stage": "Translate Paragraphs", "overall_progress": 40.1}'
    echo '@@FOLIO@@{"type": "progress_end", "stage": "Save PDF", "overall_progress": 100.0}'
    echo "secret is $PDF2ZH_OPENAI_API_KEY" >&2
    printf '%%PDF-1.4' > "$out/$stem.no_watermark.zh.mono.pdf"
    printf '%%PDF-1.4' > "$out/$stem.no_watermark.zh.dual.pdf"
    echo "@@FOLIO@@{\"type\": \"finish\", \"mono\": \"$out/$stem.no_watermark.zh.mono.pdf\", \"dual\": \"$out/$stem.no_watermark.zh.dual.pdf\"}"
    """#

    func makeRuntime(_ temp: TemporaryDirectory, engine: String) throws -> TranslatorRuntime {
        let python = try temp.script("engine/python", engine)
        return TranslatorRuntime(mode: .driver(python: python), executable: python, layout: TranslatorLayout(base: temp.url.appending(path: "base")),
                                 redirectsHome: true)
    }

    @Test func successfulRunEmitsStagesProgressAndResult() async throws {
        let temp = TemporaryDirectory()
        let runtime = try makeRuntime(temp, engine: Self.fakeEngine)
        let request = TranslationRequest(input: temp.url.appending(path: "paper.pdf"), outputDirectory: temp.url.appending(path: "out"),
                                         serviceID: "openai", secrets: ["--openai-api-key": "sk-test-secret"])
        let job = TranslationJob(request: request, runtime: runtime)
        let events = await collect(job.start())

        let stages = events.compactMap { if case .stage(let s) = $0 { s } else { nil } }
        #expect(stages == ["Starting the translation engine", "Parse PDF", "Translate paragraphs", "Save PDF"])
        let progress = events.compactMap { if case .progress(let p) = $0 { p } else { nil } }
        #expect(progress == [0, 0.4, 1])
        let mono = temp.url.appending(path: "out/paper.no_watermark.zh.mono.pdf")
        let dual = temp.url.appending(path: "out/paper.no_watermark.zh.dual.pdf")
        #expect(events.last == .finished(mono: mono, dual: dual))

        // Full log, secrets redacted, driver script installed.
        let log = try String(contentsOf: job.logURL, encoding: .utf8)
        #expect(log.contains("some log line"))
        #expect(log.contains("secret is ••••"))
        #expect(!log.contains("sk-test-secret"))
        #expect(log.contains("PDF2ZH_OPENAI_API_KEY"), "env key names are logged, values are not")
        #expect(FileManager.default.fileExists(atPath: runtime.layout.driverScript.path))
    }

    @Test func engineErrorIsMappedToChineseMessage() async throws {
        let temp = TemporaryDirectory()
        let runtime = try makeRuntime(temp, engine: """
        echo '@@FOLIO@@{"type": "stage", "stage": "translating"}'
        echo 'requests.exceptions.HTTPError: 429 Client Error: Too Many Requests' >&2
        echo '@@FOLIO@@{"type": "error", "error": "Translation subprocess initialization error: RetryError[<Future>]", "error_type": "SubprocessError", "details": ""}'
        exit 1
        """)
        let job = TranslationJob(request: .init(input: temp.url.appending(path: "a.pdf"), outputDirectory: temp.url.appending(path: "out"),
                                                serviceID: "google"), runtime: runtime)
        let events = await collect(job.start())
        guard case .failed(let message, let logURL)? = events.last else {
            Issue.record("expected failure, got \(events)")
            return
        }
        #expect(message.contains("rate limit"))
        #expect(logURL == job.logURL)
    }

    @Test func crashWithoutEventsReportsExitCode() async throws {
        let temp = TemporaryDirectory()
        let runtime = try makeRuntime(temp, engine: "echo boom >&2; exit 3")
        let job = TranslationJob(request: .init(input: temp.url.appending(path: "a.pdf"), outputDirectory: temp.url.appending(path: "out"),
                                                serviceID: "bing"), runtime: runtime)
        let events = await collect(job.start())
        #expect(events.last == .failed(message: "The translation process exited unexpectedly (code 3).", logURL: job.logURL))
    }

    @Test func configurationErrorFailsWithoutLaunching() async throws {
        let temp = TemporaryDirectory()
        let runtime = try makeRuntime(temp, engine: "touch '\(temp.url.path)/launched'")
        let job = TranslationJob(request: .init(input: temp.url.appending(path: "a.pdf"), outputDirectory: temp.url.appending(path: "out"),
                                                serviceID: "deepl"), runtime: runtime)
        let events = await collect(job.start())
        #expect(events == [.failed(message: "DeepL requires “Auth Key”. Please fill it in on the Translation page in Settings.", logURL: job.logURL)])
        #expect(!FileManager.default.fileExists(atPath: temp.url.appending(path: "launched").path))
    }

    @Test func cancelKillsTheProcessGroup() async throws {
        let temp = TemporaryDirectory()
        let pidFile = temp.url.appending(path: "worker.pid")
        let runtime = try makeRuntime(temp, engine: """
        \(termIgnoringWorker(pidFile: pidFile))
        echo '@@FOLIO@@{"type": "progress_update", "stage": "Translate Paragraphs", "overall_progress": 10.0}'
        wait
        """)
        let job = TranslationJob(request: .init(input: temp.url.appending(path: "a.pdf"), outputDirectory: temp.url.appending(path: "out"),
                                                serviceID: "bing"), runtime: runtime)
        var events: [TranslationEvent] = []
        for await event in job.start() {
            events.append(event)
            if event == .progress(0.1) { job.cancel() }
        }
        #expect(events.last == .cancelled)
        let worker = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        for _ in 0..<50 where isAlive(worker) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!isAlive(worker), "multiprocessing-style workers die with the job")
    }

    @Test func cliModeFindsOutputsByName() async throws {
        let temp = TemporaryDirectory()
        let exe = try temp.script("custom/pdf2zh_next", """
        out=""; prev=""
        for a in "$@"; do
          if [ "$prev" = "--output" ]; then out="$a"; fi
          prev="$a"
        done
        printf x > "$out/paper.no_watermark.zh.mono.pdf"
        printf x > "$out/other.no_watermark.zh.dual.pdf"
        """)
        let runtime = TranslatorRuntime(mode: .cli(executable: exe), executable: exe, layout: TranslatorLayout(base: temp.url.appending(path: "base")),
                                        redirectsHome: false)
        let job = TranslationJob(request: .init(input: temp.url.appending(path: "paper.pdf"), outputDirectory: temp.url.appending(path: "out"),
                                                serviceID: "bing"), runtime: runtime)
        let events = await collect(job.start())
        #expect(events.last == .finished(mono: temp.url.appending(path: "out/paper.no_watermark.zh.mono.pdf"), dual: nil))
    }
}
