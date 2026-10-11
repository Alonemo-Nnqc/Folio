import Foundation
import Synchronization

public enum TranslatorStatus: Sendable, Hashable {
    case notInstalled
    case installed(version: String, executableURL: URL)
    case broken(reason: String)
}

public enum TranslatorInstallPhase: String, Sendable, Hashable, CaseIterable {
    case preparing
    case downloadingUV
    case installingPackages
    case downloadingAssets
    case verifying
    case cleaningUp
    case finished

    public var title: String {
        switch self {
        case .preparing: "准备安装"
        case .downloadingUV: "下载 uv"
        case .installingPackages: "安装 Python 和 pdf2zh_next"
        case .downloadingAssets: "下载版面模型和字体"
        case .verifying: "检查安装"
        case .cleaningUp: "清理临时文件"
        case .finished: "安装完成"
        }
    }
}

public struct TranslatorInstallProgress: Sendable, Hashable {
    public var phase: TranslatorInstallPhase
    /// Overall progress 0…1.
    public var fractionCompleted: Double
    /// Short Chinese detail, e.g. "下载 onnxruntime".
    public var detail: String?
}

public enum TranslatorInstallError: Error, LocalizedError, Sendable, Equatable {
    case uvDownloadFailed(String)
    case commandFailed(step: String, summary: String, logURL: URL)
    case verificationFailed(String)
    case invalidCustomExecutable(String)
    case notInstalled
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .uvDownloadFailed(let detail): "无法下载安装工具 uv：\(detail)。请检查网络后重试。"
        case .commandFailed(let step, let summary, _): "\(step)失败：\(summary)"
        case .verificationFailed(let detail): "翻译组件安装后无法运行：\(detail)"
        case .invalidCustomExecutable(let detail): "所选的 pdf2zh_next 不可用：\(detail)"
        case .notInstalled: "翻译组件尚未安装。"
        case .cancelled: "安装已取消。"
        }
    }

    public var logURL: URL? {
        if case .commandFailed(_, _, let url) = self { return url }
        return nil
    }
}

/// Written to `installation.json` after a complete installation.
struct InstallationMarker: Codable, Sendable {
    var packageVersion: String
    var uvVersion: String
    var installedAt: Date
}

/// Manages Folio's private pdf2zh_next installation (TRANS-02).
///
/// Everything lives under `baseDirectory`; the app uses
/// `~/Library/Application Support/Folio/Translator` (see `defaultBaseDirectory`).
public struct TranslatorInstallation: Sendable {
    public static let packageName = "pdf2zh-next"
    public static let packageVersion = "2.9.0"
    /// pdf2zh-next 2.9.0 breaks with bitstring 5 (`ImportError: BitStream`).
    public static let extraRequirements = ["bitstring<5"]
    public static let pythonVersion = "3.12"

    public static var defaultBaseDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Folio/Translator", directoryHint: .isDirectory)
    }

    public let layout: TranslatorLayout
    /// A uv cache outside the base directory to reuse (never deleted). When nil,
    /// `<base>/cache` is used during installation and removed afterwards.
    public var externalUVCache: URL?
    /// Existing uv binaries to try before downloading one. Empty = always download.
    public var uvCandidates: [URL]

    public var baseDirectory: URL { layout.base }

    public init(baseDirectory: URL = TranslatorInstallation.defaultBaseDirectory, externalUVCache: URL? = nil,
                uvCandidates: [URL] = UVToolchain.defaultCandidates) {
        self.layout = TranslatorLayout(base: baseDirectory)
        self.externalUVCache = externalUVCache
        self.uvCandidates = uvCandidates
    }

    // MARK: Status

    /// Quick, file-system-only status check (does not launch Python).
    public func status() -> TranslatorStatus {
        let fm = FileManager.default
        let hasMarker = fm.fileExists(atPath: layout.marker.path)
        let hasEnvironment = fm.fileExists(atPath: layout.toolEnvironment.path)
        if !hasMarker && !hasEnvironment { return .notInstalled }
        if !hasMarker { return .broken(reason: "上次安装没有完成") }
        guard fm.isExecutableFile(atPath: layout.toolPython.path) else { return .broken(reason: "Python 环境缺失") }
        guard fm.fileExists(atPath: layout.executable.path) else { return .broken(reason: "pdf2zh_next 可执行文件缺失") }
        guard let version = layout.installedPackageVersion else { return .broken(reason: "pdf2zh_next 软件包缺失") }
        return .installed(version: version, executableURL: layout.executable)
    }

    /// Runtime for the managed installation.
    public func runtime() throws -> TranslatorRuntime {
        guard case .installed(_, let executable) = status() else { throw TranslatorInstallError.notInstalled }
        return TranslatorRuntime(mode: .driver(python: layout.toolPython), executable: executable, layout: layout, redirectsHome: true)
    }

    /// Deep check: launches the engine's Python and imports pdf2zh_next.
    /// Returns the reported version.
    public func verify() async throws -> String {
        try await Self.engineVersion(runtime: runtime())
    }

    // MARK: Custom executable

    /// Validates a user-provided `pdf2zh_next` (runs `--version`) and returns a
    /// runtime for it. Uses the driver when its Python can be located (full
    /// progress), otherwise the plain CLI. The custom engine keeps its own
    /// `~/.cache/babeldoc` assets; logs and temp files go to this base directory.
    public func customRuntime(executable: URL) async throws -> (runtime: TranslatorRuntime, version: String) {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw TranslatorInstallError.invalidCustomExecutable("文件不存在或不可执行")
        }
        let cli = TranslatorRuntime(mode: .cli(executable: executable), executable: executable, layout: layout, redirectsHome: false)
        let cliVersion: String
        do {
            cliVersion = try await Self.engineVersion(runtime: cli)
        } catch {
            throw TranslatorInstallError.invalidCustomExecutable(error.localizedDescription)
        }
        if let python = TranslatorRuntime.pythonInterpreter(forEntryPoint: executable) {
            let driver = TranslatorRuntime(mode: .driver(python: python), executable: executable, layout: layout, redirectsHome: false)
            if let version = try? await Self.engineVersion(runtime: driver) { return (driver, version) }
        }
        return (cli, cliVersion)
    }

    /// Runs `version` through the driver or `--version` through the CLI.
    static func engineVersion(runtime: TranslatorRuntime) async throws -> String {
        let spec = try runtime.spec(driverCommand: "version")
        let result = try await ChildProcess.run(spec)
        for line in result.lines {
            if case .version(let version)? = DriverEvent.parse(line.text)?.kind { return version }
            // CLI: "pdf2zh-next version: 2.9.0"
            if let range = line.text.range(of: "pdf2zh-next version: ") {
                return String(line.text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        let tail = result.lines.suffix(5).map(\.text).joined(separator: "\n")
        throw TranslatorInstallError.verificationFailed(tail.isEmpty ? "没有输出版本号（\(result.termination)）" : tail)
    }

    // MARK: Install

    /// Installs Python 3.12 + pdf2zh-next into the base directory and downloads
    /// BabelDOC's layout model, fonts and cmaps. Cancel the calling Task to abort.
    public func install(progress: @escaping @Sendable (TranslatorInstallProgress) -> Void = { _ in }) async throws {
        let fm = FileManager.default
        let logURL = layout.logsDirectory.appending(path: "install-\(TranslationJob.timestamp()).log")
        let log = LogWriter(url: logURL, redacting: [])
        defer { log.close() }
        let highWater = LockedValue(0.0)
        @Sendable func report(_ phase: TranslatorInstallPhase, _ fraction: Double, _ detail: String? = nil) {
            // Never move the bar backwards (e.g. when a download is retried).
            let value = highWater.mutate { mark -> Double in
                mark = max(mark, min(max(fraction, 0), 1))
                return mark
            }
            progress(TranslatorInstallProgress(phase: phase, fractionCompleted: value, detail: detail))
        }
        func checkCancelled() throws { if Task.isCancelled { throw TranslatorInstallError.cancelled } }

        // 1. Prepare: remove a previous (possibly broken) environment.
        report(.preparing, 0)
        try? fm.removeItem(at: layout.marker)
        for url in [layout.toolsDirectory, layout.binDirectory] where fm.fileExists(atPath: url.path) {
            try Self.forceRemove(url)
        }
        for url in [layout.base, layout.logsDirectory, layout.temporaryDirectory, layout.dataHome] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try DriverScript.install(into: layout.driverDirectory)
        log.write("Folio translator installation — \(Date())")

        // 2. uv
        let toolchain = UVToolchain(layout: layout, candidates: uvCandidates)
        var uv = await toolchain.locate()
        if uv == nil {
            try checkCancelled()
            report(.downloadingUV, 0.01, "从 GitHub 下载 uv \(UVToolchain.pinnedVersion)")
            log.write("Downloading uv \(UVToolchain.pinnedVersion) from \(UVToolchain.downloadURL())")
            uv = try await toolchain.download()
        }
        guard let uv else { throw TranslatorInstallError.uvDownloadFailed("找不到 uv") }
        log.write("Using uv \(uv.version) at \(uv.url.path)")
        report(.downloadingUV, 0.03, "uv \(uv.version)")
        try checkCancelled()

        // 3. uv tool install (0.03 … 0.60)
        let cache = externalUVCache ?? layout.cacheDirectory
        var arguments = ["tool", "install", "--python", Self.pythonVersion, "\(Self.packageName)==\(Self.packageVersion)"]
        for requirement in Self.extraRequirements { arguments += ["--with", requirement] }
        let installSpec = ProcessSpec(executable: uv.url, arguments: arguments,
                                      environment: EngineEnvironment.uv(layout: layout, cacheDirectory: cache),
                                      currentDirectory: layout.temporaryDirectory)
        log.write("$ uv \(arguments.joined(separator: " "))")
        report(.installingPackages, 0.03, "解析依赖")
        let parser = LockedValue(UVInstallProgressParser())
        let installResult = try await ChildProcess.run(installSpec) { line in
            log.write(line.text)
            if let update = parser.mutate({ $0.consume(line.text) }) {
                report(.installingPackages, 0.03 + 0.57 * update.fraction, update.detail)
            }
        }
        try checkCancelled()
        guard installResult.termination.isSuccess else {
            let summary = Self.summarize(installResult.lines.map(\.text))
            throw TranslatorInstallError.commandFailed(step: "安装 pdf2zh_next", summary: summary, logURL: logURL)
        }

        // 4. Assets (0.60 … 0.95)
        let runtime = TranslatorRuntime(mode: .driver(python: layout.toolPython), executable: layout.executable,
                                        layout: layout, redirectsHome: true)
        report(.downloadingAssets, 0.60, "检查需要下载的文件")
        let warmupResult = try await ChildProcess.run(try runtime.spec(driverCommand: "warmup")) { line in
            log.write(line.text)
            guard let event = DriverEvent.parse(line.text) else { return }
            switch event.kind {
            case .warmupStart(let total):
                report(.downloadingAssets, 0.61, total == 0 ? "资源已存在" : "需要下载 \(total) 个文件")
            case .warmupProgress(let done, let total, let file):
                report(.downloadingAssets, 0.61 + 0.34 * Double(done) / Double(max(total, 1)),
                       "已下载 \(done)/\(total)" + (file.map { "：\($0)" } ?? ""))
            case .warmupRetry(_, let remaining):
                report(.downloadingAssets, 0, "网络不稳定，正在重试剩余 \(remaining) 个文件")
            default: break
            }
        }
        try checkCancelled()
        guard warmupResult.termination.isSuccess else {
            let message = warmupResult.lines.compactMap { line -> String? in
                if case .error(let message, _, _)? = DriverEvent.parse(line.text)?.kind { return message }
                return nil
            }.last ?? Self.summarize(warmupResult.lines.map(\.text))
            throw TranslatorInstallError.commandFailed(step: "下载版面模型和字体", summary: message, logURL: logURL)
        }

        // 5. Verify (0.95 … 0.98)
        report(.verifying, 0.95, "启动翻译引擎")
        let version: String
        do {
            version = try await Self.engineVersion(runtime: runtime)
        } catch {
            log.write("Verification failed: \(error)")
            throw error
        }
        log.write("pdf2zh_next \(version) OK")

        // 6. Clean up the uv cache (the environment does not reference it).
        report(.cleaningUp, 0.98)
        if externalUVCache == nil { try? Self.forceRemove(layout.cacheDirectory) }
        try? Self.forceRemove(layout.temporaryDirectory)
        try fm.createDirectory(at: layout.temporaryDirectory, withIntermediateDirectories: true)

        let marker = InstallationMarker(packageVersion: version, uvVersion: uv.version, installedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: layout.marker, options: .atomic)
        report(.finished, 1, "pdf2zh_next \(version)")
    }

    // MARK: Uninstall

    /// Removes everything Folio installed (environment, Python, assets, caches,
    /// downloaded uv). Logs are kept.
    public func uninstall() throws {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: layout.base, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent != "logs" {
            try Self.forceRemove(entry)
        }
    }

    /// Bytes used by the installation (for the settings page).
    public func diskUsage() -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: layout.base, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Helpers

    /// Removes a directory even when uv left read-only files in it.
    static func forceRemove(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil else { return }
        do {
            try fm.removeItem(at: url)
        } catch {
            if let enumerator = fm.enumerator(atPath: url.path) {
                for case let relative as String in enumerator {
                    let path = url.appending(path: relative).path
                    if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil { continue }
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
                }
            }
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try fm.removeItem(at: url)
        }
    }

    /// The most informative lines of a failed command.
    static func summarize(_ lines: [String]) -> String {
        let interesting = lines.filter {
            let lower = $0.lowercased()
            return lower.contains("error") || lower.contains("failed") || lower.contains("×")
        }
        let chosen = (interesting.isEmpty ? Array(lines.suffix(3)) : Array(interesting.suffix(3)))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let text = chosen.joined(separator: "；")
        return text.isEmpty ? "未知错误" : String(text.prefix(300))
    }
}

/// Minimal lock-protected box for callback state.
final class LockedValue<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>
    init(_ value: Value) { mutex = Mutex(value) }
    func mutate<R: Sendable>(_ body: (inout Value) -> R) -> R { mutex.withLock { body(&$0) } }
}
