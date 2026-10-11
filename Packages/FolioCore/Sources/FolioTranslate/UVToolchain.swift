import CryptoKit
import Foundation

/// Locates or downloads `uv` (https://github.com/astral-sh/uv).
public struct UVToolchain: Sendable {
    /// uv release downloaded when no usable uv is found on this Mac.
    public static let pinnedVersion = "0.12.6"

    /// Where an existing uv is looked for (after Folio's own copy).
    public static var defaultCandidates: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [home.appending(path: ".local/bin/uv"), home.appending(path: ".cargo/bin/uv"),
                URL(fileURLWithPath: "/opt/homebrew/bin/uv"), URL(fileURLWithPath: "/usr/local/bin/uv")]
    }

    public var layout: TranslatorLayout
    public var candidates: [URL]
    public var session: URLSession

    public init(layout: TranslatorLayout, candidates: [URL] = UVToolchain.defaultCandidates, session: URLSession = .shared) {
        self.layout = layout
        self.candidates = candidates
        self.session = session
    }

    /// Returns a working uv: Folio's copy, an existing installation, or nil.
    public func locate() async -> (url: URL, version: String)? {
        for url in [layout.bundledUV] + candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            if let version = await Self.version(of: url, layout: layout) { return (url, version) }
        }
        return nil
    }

    /// `uv --version` → "0.12.6", or nil when it does not run.
    static func version(of url: URL, layout: TranslatorLayout) async -> String? {
        let spec = ProcessSpec(executable: url, arguments: ["--version"], environment: EngineEnvironment.base(layout: nil),
                               currentDirectory: FileManager.default.temporaryDirectory)
        guard let result = try? await ChildProcess.run(spec), result.termination.isSuccess else { return nil }
        let text = result.lines.first { $0.stream == .stdout }?.text ?? ""
        guard text.hasPrefix("uv ") else { return nil }
        return text.split(separator: " ").dropFirst().first.map(String.init)
    }

    /// Release asset name for this Mac's architecture.
    public static var assetName: String {
        #if arch(arm64)
        "uv-aarch64-apple-darwin"
        #else
        "uv-x86_64-apple-darwin"
        #endif
    }

    public static func downloadURL(version: String = pinnedVersion) -> URL {
        URL(string: "https://github.com/astral-sh/uv/releases/download/\(version)/\(assetName).tar.gz")!
    }

    /// Downloads the official uv release into `<base>/uv/uv`, verifies its
    /// SHA-256 against the published `.sha256` file and checks that it runs.
    public func download(version: String = pinnedVersion) async throws -> (url: URL, version: String) {
        let archiveURL = Self.downloadURL(version: version)
        let checksumURL = URL(string: archiveURL.absoluteString + ".sha256")!
        let (checksumData, checksumResponse) = try await session.data(from: checksumURL)
        try Self.checkHTTP(checksumResponse, url: checksumURL)
        guard let expected = String(decoding: checksumData, as: UTF8.self).split(separator: " ").first.map({ $0.lowercased() }),
              expected.count == 64 else {
            throw TranslatorInstallError.uvDownloadFailed("无法读取 uv 的校验值")
        }
        let (downloaded, response) = try await session.download(from: archiveURL)
        try Self.checkHTTP(response, url: archiveURL)
        let data = try Data(contentsOf: downloaded, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw TranslatorInstallError.uvDownloadFailed("uv 下载文件校验失败")
        }

        let fm = FileManager.default
        let staging = layout.temporaryDirectory.appending(path: "uv-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appending(path: "uv.tar.gz")
        try fm.moveItem(at: downloaded, to: archive)
        let untar = ProcessSpec(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", staging.path],
                                environment: EngineEnvironment.base(layout: nil), currentDirectory: staging)
        let result = try await ChildProcess.run(untar)
        guard result.termination.isSuccess else { throw TranslatorInstallError.uvDownloadFailed("无法解压 uv") }
        let extracted = staging.appending(path: "\(Self.assetName)/uv")
        guard fm.isExecutableFile(atPath: extracted.path) else { throw TranslatorInstallError.uvDownloadFailed("压缩包中没有 uv") }

        try fm.createDirectory(at: layout.uvDirectory, withIntermediateDirectories: true)
        try? fm.removeItem(at: layout.bundledUV)
        try fm.moveItem(at: extracted, to: layout.bundledUV)
        guard let runningVersion = await Self.version(of: layout.bundledUV, layout: layout) else {
            throw TranslatorInstallError.uvDownloadFailed("下载的 uv 无法运行")
        }
        return (layout.bundledUV, runningVersion)
    }

    private static func checkHTTP(_ response: URLResponse, url: URL) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TranslatorInstallError.uvDownloadFailed("HTTP \(http.statusCode)：\(url.lastPathComponent)")
        }
    }
}

/// Coarse progress parsed from `uv tool install` output (non-TTY mode):
///
/// ```
/// Downloading cpython-3.12.14-macos-aarch64-none (download) (23.8MiB)
///  Downloaded cpython-3.12.14-macos-aarch64-none (download)
/// Resolved 133 packages in 9.57s
/// Downloading pillow (4.5MiB)
///  Downloaded pillow
/// Prepared 133 packages in 1m 51s
/// Installed 133 packages in 206ms
/// Installed 3 executables: pdf2zh, pdf2zh2, pdf2zh_next
/// ```
struct UVInstallProgressParser: Sendable {
    enum Step: Sendable, Hashable { case python, resolving, downloading, installing, done }

    private(set) var step: Step = .resolving
    private(set) var announced = 0
    private(set) var downloaded = 0
    private(set) var pythonDownloaded = false

    /// Fraction of the uv step, 0…1, after consuming `line`. Returns nil when unchanged.
    mutating func consume(_ line: String) -> (fraction: Double, detail: String)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("Downloading cpython") {
            step = .python
            return (0.02, "下载 Python 3.12")
        }
        if text.hasPrefix("Downloaded cpython") {
            pythonDownloaded = true
            return (0.08, "已下载 Python 3.12")
        }
        if text.hasPrefix("Resolved ") {
            step = .downloading
            return (0.12, "已解析依赖：\(text.split(separator: " ").dropFirst().first ?? "") 个包")
        }
        if text.hasPrefix("Downloading ") {
            announced += 1
            return (fraction, "下载 \(Self.packageName(text))")
        }
        if text.hasPrefix("Downloaded ") {
            downloaded += 1
            return (fraction, "已下载 \(downloaded)/\(max(announced, downloaded)) 个大文件")
        }
        if text.hasPrefix("Prepared ") {
            step = .installing
            return (0.9, "正在安装软件包")
        }
        if text.hasPrefix("Installed ") && text.contains("executable") {
            step = .done
            return (1, "软件包安装完成")
        }
        if text.hasPrefix("Installed ") {
            return (0.95, "软件包已安装")
        }
        return nil
    }

    private var fraction: Double {
        guard announced > 0 else { return 0.12 }
        return 0.12 + 0.76 * Double(downloaded) / Double(max(announced, downloaded))
    }

    private static func packageName(_ text: String) -> String {
        text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }
}
