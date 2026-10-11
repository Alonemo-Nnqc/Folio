import Foundation
import Synchronization

/// Runs one PDF translation in a separate process group.
///
/// ```swift
/// let job = TranslationJob(request: request, runtime: try installation.runtime())
/// for await event in job.start() { … }   // .stage / .progress / .finished / .failed / .cancelled
/// job.cancel()                            // from anywhere; kills the whole process group
/// ```
///
/// The full stdout/stderr of the engine is written to `logURL` (secrets are
/// passed through the environment and redacted from the log).
public final class TranslationJob: Sendable {
    public let request: TranslationRequest
    public let runtime: TranslatorRuntime
    public let logURL: URL
    private let appleTranslatorCommand: [String]?
    private let state = Mutex(State())

    private struct State {
        var started = false
        var cancelled = false
        var process: ChildProcess?
    }

    /// - Parameters:
    ///   - logURL: defaults to `<translator>/logs/translate-<date>-<uuid>.log`.
    ///   - appleTranslatorCommand: executable (+ leading arguments) of the Apple
    ///     translation helper; required when `request.serviceID == "apple"`.
    public init(request: TranslationRequest, runtime: TranslatorRuntime, logURL: URL? = nil,
                appleTranslatorCommand: [String]? = nil) {
        self.request = request
        self.runtime = runtime
        self.appleTranslatorCommand = appleTranslatorCommand
        self.logURL = logURL ?? runtime.layout.logsDirectory.appending(
            path: "translate-\(Self.timestamp())-\(UUID().uuidString.prefix(8)).log")
    }

    /// Starts the job. Call once; later calls return a stream that finishes immediately.
    public func start() -> AsyncStream<TranslationEvent> {
        let (stream, continuation) = AsyncStream<TranslationEvent>.makeStream(bufferingPolicy: .unbounded)
        let alreadyStarted = state.withLock { state -> Bool in
            defer { state.started = true }
            return state.started
        }
        if alreadyStarted {
            continuation.finish()
            return stream
        }
        let task = Task.detached { [self] in
            await run(continuation)
            continuation.finish()
        }
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                self?.cancel()
                task.cancel()
            }
        }
        return stream
    }

    /// Cancels the job: SIGTERM to the whole process group, SIGKILL after 3 s.
    public func cancel() {
        let process = state.withLock { state -> ChildProcess? in
            state.cancelled = true
            return state.process
        }
        process?.terminateGroup(grace: 3)
    }

    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    // MARK: - Running

    private func run(_ continuation: AsyncStream<TranslationEvent>.Continuation) async {
        let log = LogWriter(url: logURL, redacting: Array(request.secrets.values))
        defer { log.close() }

        let commandLine: TranslationCommandLine
        let spec: ProcessSpec
        do {
            commandLine = try TranslationArgumentBuilder.build(request, appleTranslatorCommand: appleTranslatorCommand)
            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
            spec = try runtime.spec(driverCommand: "translate", arguments: commandLine.arguments,
                                    extraEnvironment: commandLine.environment)
        } catch {
            log.write("Configuration error: \(error)")
            continuation.yield(.failed(message: error.localizedDescription, logURL: logURL))
            return
        }

        log.write("Folio translation job — \(Date())")
        log.write("Executable: \(spec.executable.path)")
        log.write("Arguments: \(spec.arguments.joined(separator: " "))")
        log.write("Environment keys: \(spec.environment.keys.sorted().joined(separator: ", "))")
        log.write("---")

        if isCancelled {
            continuation.yield(.cancelled)
            return
        }
        let process: ChildProcess
        do {
            process = try ChildProcess.launch(spec)
        } catch {
            log.write("Launch failed: \(error)")
            continuation.yield(.failed(message: "无法启动翻译组件（\(error.localizedDescription)）。请在设置的“翻译”页重新安装组件。",
                                       logURL: logURL))
            return
        }
        let cancelledBeforeStore = state.withLock { state -> Bool in
            state.process = process
            return state.cancelled
        }
        if cancelledBeforeStore { process.terminateGroup(grace: 3) }

        var tracker = ProgressTracker()
        if let stage = tracker.stage("starting") { continuation.yield(.stage(stage)) }
        continuation.yield(.progress(0))
        var finish: (mono: String?, dual: String?)?
        var engineError: (message: String, details: String?)?
        var tail: [String] = []

        for await line in process.output {
            log.write(line.text)
            if let event = DriverEvent.parse(line.text) {
                switch event.kind {
                case .stage(let name):
                    if let stage = tracker.stage(name) { continuation.yield(.stage(stage)) }
                case .progress(let stage, let overall, _, _):
                    if let stage, let display = tracker.stage(stage) { continuation.yield(.stage(display)) }
                    if let overall, let value = tracker.progress(overall / 100) { continuation.yield(.progress(value)) }
                case .finish(let mono, let dual, _):
                    finish = (mono, dual)
                case .error(let message, _, let details):
                    engineError = (message, details)
                default:
                    break
                }
            } else {
                tail.append(line.text)
                if tail.count > 60 { tail.removeFirst(tail.count - 60) }
            }
        }
        let termination = await process.waitUntilExit()
        // Reap any stray worker that outlived the leader.
        process.killGroup()
        log.write("--- process ended: \(termination)")

        if isCancelled {
            continuation.yield(.cancelled)
            return
        }

        let fm = FileManager.default
        func existing(_ path: String?) -> URL? {
            guard let path, fm.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        if let finish, termination.isSuccess || existing(finish.mono) != nil || existing(finish.dual) != nil {
            let mono = existing(finish.mono), dual = existing(finish.dual)
            if mono != nil || dual != nil {
                if tracker.lastProgress < 1 { continuation.yield(.progress(1)) }
                continuation.yield(.finished(mono: mono, dual: dual))
                return
            }
        }
        if case .cli = runtime.mode, termination.isSuccess {
            let found = Self.scanOutputs(in: request.outputDirectory, input: request.input)
            if found.mono != nil || found.dual != nil {
                continuation.yield(.progress(1))
                continuation.yield(.finished(mono: found.mono, dual: found.dual))
                return
            }
        }

        let failure: TranslationFailure
        if let engineError {
            failure = TranslationErrorClassifier.classify(message: engineError.message, details: engineError.details, logTail: tail)
        } else {
            let summary = switch termination {
            case .exited(let code): "翻译进程意外退出（代码 \(code)）"
            case .signaled(let signal): signal == SIGKILL ? "翻译进程被系统终止（可能内存不足）" : "翻译进程意外终止（信号 \(signal)）"
            }
            let classified = TranslationErrorClassifier.classify(message: summary, logTail: tail)
            failure = classified.reason == .unknown
                ? TranslationFailure(reason: .unknown, message: summary + "。", rawMessage: summary)
                : classified
        }
        log.write("Failure (\(failure.reason.rawValue)): \(failure.message) — \(failure.rawMessage)")
        continuation.yield(.failed(message: failure.message, logURL: logURL))
    }

    /// Finds `<stem>…mono.pdf` / `<stem>…dual.pdf` written by pdf2zh_next.
    static func scanOutputs(in directory: URL, input: URL) -> (mono: URL?, dual: URL?) {
        let stem = input.deletingPathExtension().lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let names = files.map(\.lastPathComponent).filter { $0.hasPrefix(stem + ".") && $0.lowercased().hasSuffix(".pdf") }.sorted()
        return (names.first { $0.hasSuffix(".mono.pdf") }.map { directory.appending(path: $0) },
                names.first { $0.hasSuffix(".dual.pdf") }.map { directory.appending(path: $0) })
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// Deduplicates stages and keeps progress monotonic.
struct ProgressTracker {
    private(set) var lastStage: String?
    private(set) var lastProgress: Double = 0

    /// Returns the display name when the stage changed.
    mutating func stage(_ raw: String) -> String? {
        let display = TranslationStageNames.displayName(for: raw)
        guard !raw.isEmpty, display != lastStage else { return nil }
        lastStage = display
        return display
    }

    /// Returns the new value when it advanced by at least 0.5 %.
    mutating func progress(_ value: Double) -> Double? {
        let clamped = min(max(value, 0), 1)
        guard clamped >= lastProgress + 0.005 || (clamped == 1 && lastProgress < 1) else { return nil }
        lastProgress = clamped
        return clamped
    }
}

/// Appends lines to a log file, redacting secrets.
final class LogWriter: Sendable {
    private let handle: FileHandle?
    private let secrets: [String]

    init(url: URL, redacting secrets: [String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        self.secrets = secrets.filter { $0.count >= 4 }
    }

    func write(_ line: String) {
        var text = line
        for secret in secrets { text = text.replacingOccurrences(of: secret, with: "••••") }
        try? handle?.write(contentsOf: Data((text + "\n").utf8))
    }

    func close() { try? handle?.close() }
}
