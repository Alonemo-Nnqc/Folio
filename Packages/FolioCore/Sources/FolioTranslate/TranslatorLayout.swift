import Foundation

/// Directory layout of a Folio-managed translator installation.
///
/// ```
/// <base>/
///   uv/uv                    uv binary downloaded by Folio (only when no uv was found)
///   tools/pdf2zh-next/       the tool's virtual environment (UV_TOOL_DIR)
///   bin/pdf2zh_next          entry points (UV_TOOL_BIN_DIR)
///   python/                  uv-managed CPython 3.12 (UV_PYTHON_INSTALL_DIR)
///   python-bin/              (UV_PYTHON_BIN_DIR, normally empty)
///   cache/                   uv cache during installation (UV_CACHE_DIR, removed afterwards)
///   home/                    `~` for the Python process: .cache/babeldoc (models, fonts, cmaps,
///                            tiktoken), .cache/pdf2zh_next (translation cache), .config/pdf2zh
///   driver/                  folio_pdf2zh_driver.py
///   logs/                    install / translation logs
///   tmp/                     TMPDIR for the engine
///   installation.json        written after a complete installation
/// ```
public struct TranslatorLayout: Sendable, Hashable {
    public let base: URL

    public init(base: URL) { self.base = base }

    public var uvDirectory: URL { base.appending(path: "uv", directoryHint: .isDirectory) }
    public var bundledUV: URL { uvDirectory.appending(path: "uv") }
    public var toolsDirectory: URL { base.appending(path: "tools", directoryHint: .isDirectory) }
    public var toolEnvironment: URL { toolsDirectory.appending(path: "pdf2zh-next", directoryHint: .isDirectory) }
    public var toolPython: URL { toolEnvironment.appending(path: "bin/python") }
    public var binDirectory: URL { base.appending(path: "bin", directoryHint: .isDirectory) }
    public var executable: URL { binDirectory.appending(path: "pdf2zh_next") }
    public var pythonInstallDirectory: URL { base.appending(path: "python", directoryHint: .isDirectory) }
    public var pythonBinDirectory: URL { base.appending(path: "python-bin", directoryHint: .isDirectory) }
    public var cacheDirectory: URL { base.appending(path: "cache", directoryHint: .isDirectory) }
    /// Redirected `~` for the engine's own caches and config.
    public var dataHome: URL { base.appending(path: "home", directoryHint: .isDirectory) }
    /// BabelDOC assets (layout model, fonts, cmaps, tiktoken).
    public var assetsDirectory: URL { dataHome.appending(path: ".cache/babeldoc", directoryHint: .isDirectory) }
    public var driverDirectory: URL { base.appending(path: "driver", directoryHint: .isDirectory) }
    public var driverScript: URL { driverDirectory.appending(path: DriverScript.fileName) }
    public var logsDirectory: URL { base.appending(path: "logs", directoryHint: .isDirectory) }
    public var temporaryDirectory: URL { base.appending(path: "tmp", directoryHint: .isDirectory) }
    public var marker: URL { base.appending(path: "installation.json") }

    /// `lib/python3.x/site-packages` of the tool environment, if present.
    public var sitePackages: URL? {
        let lib = toolEnvironment.appending(path: "lib", directoryHint: .isDirectory)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: lib.path) else { return nil }
        guard let python = entries.sorted().last(where: { $0.hasPrefix("python3") }) else { return nil }
        return lib.appending(path: "\(python)/site-packages", directoryHint: .isDirectory)
    }

    /// Version of pdf2zh_next according to its `.dist-info` directory.
    public var installedPackageVersion: String? {
        guard let sitePackages, let entries = try? FileManager.default.contentsOfDirectory(atPath: sitePackages.path) else { return nil }
        for entry in entries where entry.hasPrefix("pdf2zh_next-") && entry.hasSuffix(".dist-info") {
            return String(entry.dropFirst("pdf2zh_next-".count).dropLast(".dist-info".count))
        }
        return nil
    }
}

/// Builds the explicit environment for engine processes. Nothing from the
/// host app's environment leaks in except proxies, HOME/USER and TMPDIR.
enum EngineEnvironment {
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Proxy variables honoured by uv, httpx and requests.
    static let passthroughKeys = ["http_proxy", "https_proxy", "all_proxy", "no_proxy",
                                  "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
                                  "SSL_CERT_FILE", "SSL_CERT_DIR"]

    static func base(layout: TranslatorLayout?, extraPath: [URL] = [], host: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env: [String: String] = [:]
        let pathEntries = extraPath.map(\.path) + [systemPath]
        env["PATH"] = pathEntries.joined(separator: ":")
        env["HOME"] = host["HOME"] ?? NSHomeDirectory()
        if let user = host["USER"] { env["USER"] = user }
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        // Keep rich from wrapping long log lines (paths) at 80 columns.
        env["COLUMNS"] = "400"
        if let layout {
            env["TMPDIR"] = layout.temporaryDirectory.path + "/"
            env["FOLIO_TRANSLATOR_HOME"] = layout.dataHome.path
        } else {
            env["TMPDIR"] = host["TMPDIR"] ?? NSTemporaryDirectory()
        }
        for key in passthroughKeys { if let value = host[key] { env[key] = value } }
        return env
    }

    static func uv(layout: TranslatorLayout, cacheDirectory: URL) -> [String: String] {
        var env = base(layout: layout)
        env["UV_TOOL_DIR"] = layout.toolsDirectory.path
        env["UV_TOOL_BIN_DIR"] = layout.binDirectory.path
        env["UV_PYTHON_INSTALL_DIR"] = layout.pythonInstallDirectory.path
        env["UV_PYTHON_BIN_DIR"] = layout.pythonBinDirectory.path
        env["UV_CACHE_DIR"] = cacheDirectory.path
        // Never pick up Homebrew / system Pythons: a later `brew upgrade` would break the env.
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        // Ignore the user's uv.toml / pyproject settings.
        env["UV_NO_CONFIG"] = "1"
        return env
    }
}
