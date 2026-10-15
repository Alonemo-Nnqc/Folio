import Foundation

/// Finds a `pdf2zh_next` the user installed themselves (设置 ▸ 翻译 ▸ 使用自己安装的 pdf2zh_next, and the
/// `find_pdf2zh_next` MCP tool), so it is configured without browsing for the file. Candidates come from the
/// shell's PATH, the places uv, pipx, Homebrew, pyenv, conda / mamba and virtualenv tools install commands,
/// the zotero-pdf2zh plugin's server, then Spotlight and a short scan of the home folder for virtual
/// environments anywhere (`~/projects/x/.venv/bin/pdf2zh_next`). Each one must answer `--version`.
public enum TranslatorDiscovery {
    public static let commandNames = ["pdf2zh_next", "pdf2zh-next"]

    /// Existing executables named like pdf2zh_next, most likely first, without duplicates (symlinks resolved)
    /// and never Folio's own copy under `excluding`.
    public static func candidates(home: URL, pathFolders: [String], excluding: URL? = nil, deep: Bool = false,
                                  spotlight useSpotlight: Bool = true) -> [URL] {
        let fm = FileManager.default
        var folders = pathFolders
        folders += [".local/bin", ".local/share/uv/tools/pdf2zh-next/bin", ".local/pipx/venvs/pdf2zh-next/bin",
                    ".local/pipx/venvs/pdf2zh_next/bin", ".pyenv/shims"].map { home.appending(path: $0).path }
        folders += ["/opt/homebrew/bin", "/usr/local/bin"]
        // Virtual environments in the usual places: virtualenvwrapper, pyenv versions, ~/venv(s), ~/.venv, and the
        // server folder of the zotero-pdf2zh plugin (~/zotero-pdf2zh/server/zotero-pdf2zh-next-venv).
        for parent in [".virtualenvs", ".pyenv/versions", "venvs", ".venvs", "zotero-pdf2zh/server", "zotero-pdf2zh"] {
            folders += subfolders(of: home.appending(path: parent)).map { $0.appending(path: "bin").path }
        }
        folders += ["venv/bin", ".venv/bin"].map { home.appending(path: $0).path }
        // User-site scripts of each Python (pip install --user).
        folders += subfolders(of: home.appending(path: "Library/Python")).map { $0.appending(path: "bin").path }
        // conda / mamba: the base environment and every named one.
        let condaRoots = ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "micromamba", ".conda"].map { home.appending(path: $0) }
            + ["/opt/homebrew/Caskroom/miniconda/base", "/opt/miniconda3", "/opt/anaconda3"].map { URL(filePath: $0) }
        for root in condaRoots {
            folders.append(root.appending(path: "bin").path)
            folders += subfolders(of: root.appending(path: "envs")).map { $0.appending(path: "bin").path }
        }
        if deep {
            if useSpotlight { folders += spotlight().map { $0.deletingLastPathComponent().path } }
            folders += scanHome(home).map { $0.deletingLastPathComponent().path }
        }
        let excluded = excluding.map { $0.resolvingSymlinksInPath().path + "/" }
        var seen = Set<String>()
        var found: [URL] = []
        for folder in folders {
            for name in commandNames {
                let url = URL(filePath: folder).appending(path: name)
                var isFolder: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue,
                      fm.isExecutableFile(atPath: url.path) else { continue }
                let real = url.resolvingSymlinksInPath().path
                if let excluded, real.hasPrefix(excluded) { continue }
                if seen.insert(real).inserted { found.append(url) }
            }
        }
        return found
    }

    /// The first candidate that runs and reports its version. The usual places are tried first; Spotlight and
    /// the home-folder scan only when they find nothing.
    public static func discover(installation: TranslatorInstallation, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                pathFolders: [String], spotlight: Bool = true) async -> (executable: URL, version: String)? {
        for deep in [false, true] {
            var tried = Set<String>()
            for candidate in candidates(home: home, pathFolders: pathFolders, excluding: installation.baseDirectory, deep: deep,
                                        spotlight: spotlight)
            where tried.insert(candidate.path).inserted {
                if let (_, version) = try? await installation.customRuntime(executable: candidate) { return (candidate, version) }
            }
        }
        return nil
    }

    /// Every candidate with its version or the reason it does not run (the `find_pdf2zh_next` tool).
    public static func survey(installation: TranslatorInstallation, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              pathFolders: [String]) async -> [(executable: URL, result: Result<String, Error>)] {
        var results: [(URL, Result<String, Error>)] = []
        for candidate in candidates(home: home, pathFolders: pathFolders, excluding: installation.baseDirectory, deep: true) {
            do {
                results.append((candidate, .success(try await installation.customRuntime(executable: candidate).version)))
            } catch {
                results.append((candidate, .failure(error)))
            }
        }
        return results
    }

    /// Where the search looks, for messages to the user.
    public static let searchedPlaces = String(localized: "终端的 PATH、uv / pipx / conda / pyenv / Homebrew / virtualenv 的安装位置、zotero-pdf2zh 插件目录、Spotlight 以及主文件夹中的虚拟环境", bundle: .module)

    /// Files Spotlight knows by these names (it indexes the home folder, though not hidden folders).
    static func spotlight() -> [URL] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/mdfind")
        process.arguments = [commandNames.map { "kMDItemFSName == '\($0)'" }.joined(separator: " || ")]
        // A file rather than a pipe, and a deadline: Spotlight may be slow or disabled.
        let log = FileManager.default.temporaryDirectory.appending(path: "folio-mdfind-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        guard let output = try? FileHandle(forWritingTo: log) else { return [] }
        defer { try? output.close() }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return [] }
        if finished.wait(timeout: .now() + 3) == .timedOut { process.terminate(); return [] }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { URL(filePath: String($0)) }
            .filter { $0.deletingLastPathComponent().lastPathComponent == "bin" }
    }

    /// `bin/pdf2zh_next` in virtual environments under the home folder (folders holding `pyvenv.cfg`), at most
    /// `maxDepth` folders down and for at most `budget` seconds. Skips Library, caches, package and media
    /// folders and hidden folders other than environment ones.
    static func scanHome(_ home: URL, maxDepth: Int = 6, budget: TimeInterval = 3) -> [URL] {
        let skipped: Set<String> = ["Library", "Applications", "Pictures", "Movies", "Music", "node_modules", "site-packages",
                                    "__pycache__", "Caches", "DerivedData", ".Trash", ".git", ".cache", ".npm", ".cargo", ".rustup"]
        let hiddenAllowed: Set<String> = [".venv", ".venvs", ".virtualenvs", ".conda", ".pyenv", ".local", ".share"]
        guard let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                              options: [.skipsPackageDescendants]) else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        var found: [URL] = []
        for case let url as URL in enumerator {
            if Date() > deadline { break }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            if skipped.contains(name) || (name.hasPrefix(".") && !hiddenAllowed.contains(name)) || enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard FileManager.default.fileExists(atPath: url.appending(path: "pyvenv.cfg").path) else { continue }
            enumerator.skipDescendants()
            for command in commandNames {
                let candidate = url.appending(path: "bin/\(command)")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { found.append(candidate) }
            }
        }
        return found
    }

    private static func subfolders(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest Python version first
    }
}
