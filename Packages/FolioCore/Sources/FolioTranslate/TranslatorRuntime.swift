import Foundation

/// How to run the translation engine: either through Folio's Python driver
/// (preferred: machine-readable progress) or, for a custom `pdf2zh_next`
/// whose Python cannot be located, the plain CLI.
public struct TranslatorRuntime: Sendable, Hashable {
    public enum Mode: Sendable, Hashable {
        /// Run `python -u folio_pdf2zh_driver.py …` with this interpreter.
        case driver(python: URL)
        /// Run the `pdf2zh_next` executable directly (coarse progress only).
        case cli(executable: URL)
    }

    public var mode: Mode
    /// The `pdf2zh_next` entry point this runtime belongs to.
    public var executable: URL
    /// Folio's translator directory (driver script, logs, tmp, redirected home).
    public var layout: TranslatorLayout
    /// Redirect `~` of the engine into `layout.dataHome` (BabelDOC assets, caches, config).
    /// True for the managed installation; false for a custom executable so it keeps
    /// using the assets it already downloaded under `~/.cache/babeldoc`.
    public var redirectsHome: Bool

    public init(mode: Mode, executable: URL, layout: TranslatorLayout, redirectsHome: Bool) {
        self.mode = mode
        self.executable = executable
        self.layout = layout
        self.redirectsHome = redirectsHome
    }

    /// Environment for engine processes (without secrets).
    func environment() -> [String: String] {
        var env = EngineEnvironment.base(layout: layout, extraPath: [executable.deletingLastPathComponent()])
        if !redirectsHome { env.removeValue(forKey: "FOLIO_TRANSLATOR_HOME") }
        return env
    }

    /// Process spec for a driver command (`version`, `warmup`, `translate …`)
    /// or, in CLI mode, the equivalent CLI invocation.
    func spec(driverCommand: String, arguments: [String] = [], extraEnvironment: [String: String] = [:]) throws -> ProcessSpec {
        for directory in [layout.temporaryDirectory, layout.logsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let env = environment().merging(extraEnvironment) { _, new in new }
        switch mode {
        case .driver(let python):
            let script = try DriverScript.install(into: layout.driverDirectory)
            return ProcessSpec(executable: python, arguments: ["-u", script.path, driverCommand] + arguments,
                               environment: env, currentDirectory: layout.temporaryDirectory)
        case .cli(let executable):
            let cliArguments: [String] = switch driverCommand {
            case "version": ["--version"]
            case "warmup": ["--warmup"]
            default: arguments
            }
            return ProcessSpec(executable: executable, arguments: cliArguments, environment: env,
                               currentDirectory: layout.temporaryDirectory)
        }
    }

    /// Finds the Python interpreter behind a `pdf2zh_next` entry point:
    /// a `python` next to the (symlink-resolved) script, or the interpreter
    /// named in its shebang / uv's `exec` trampoline.
    public static func pythonInterpreter(forEntryPoint executable: URL) -> URL? {
        let fm = FileManager.default
        let resolved = executable.resolvingSymlinksInPath()
        for name in ["python", "python3"] {
            let candidate = resolved.deletingLastPathComponent().appending(path: name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        guard let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 2048)) ?? Data(), as: UTF8.self)
        let lines = head.split(separator: "\n", maxSplits: 4).map(String.init)
        guard let first = lines.first, first.hasPrefix("#!") else { return nil }
        var candidates: [String] = []
        // uv / pip trampoline for long paths: '''exec' '/path/to/python' "$0" "$@"
        for line in lines.dropFirst() {
            if let match = line.firstMatch(of: /exec' '([^']+)'/) { candidates.append(String(match.1)) }
        }
        let shebang = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if let path = shebang.split(separator: " ").first, path.contains("python") { candidates.append(String(path)) }
        return candidates.lazy.map { URL(fileURLWithPath: $0) }.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
