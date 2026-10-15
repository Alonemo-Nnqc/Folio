import Foundation

/// Finds a `pdf2zh_next` the user installed themselves (设置 ▸ 翻译 ▸ 使用自己安装的 pdf2zh_next), so turning the
/// option on configures it without browsing for the file. Candidates come from the shell's PATH and the places
/// uv, pipx, Homebrew, pyenv and conda / mamba install command-line tools; each one must answer `--version`.
public enum TranslatorDiscovery {
    public static let commandNames = ["pdf2zh_next", "pdf2zh-next"]

    /// Existing executables named like pdf2zh_next, most likely first, without duplicates (symlinks resolved)
    /// and never Folio's own copy under `excluding`.
    public static func candidates(home: URL, pathFolders: [String], excluding: URL? = nil) -> [URL] {
        let fm = FileManager.default
        var folders = pathFolders
        folders += [".local/bin", ".local/share/uv/tools/pdf2zh-next/bin", ".local/pipx/venvs/pdf2zh-next/bin",
                    ".local/pipx/venvs/pdf2zh_next/bin", ".pyenv/shims"].map { home.appending(path: $0).path }
        folders += ["/opt/homebrew/bin", "/usr/local/bin"]
        // User-site scripts of each Python (pip install --user).
        folders += subfolders(of: home.appending(path: "Library/Python")).map { $0.appending(path: "bin").path }
        // conda / mamba: the base environment and every named one.
        let condaRoots = ["miniconda3", "anaconda3", "miniforge3", "mambaforge", "micromamba", ".conda"].map { home.appending(path: $0) }
            + ["/opt/homebrew/Caskroom/miniconda/base", "/opt/miniconda3", "/opt/anaconda3"].map { URL(filePath: $0) }
        for root in condaRoots {
            folders.append(root.appending(path: "bin").path)
            folders += subfolders(of: root.appending(path: "envs")).map { $0.appending(path: "bin").path }
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

    /// The first candidate that runs and reports its version.
    public static func discover(installation: TranslatorInstallation, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                pathFolders: [String]) async -> (executable: URL, version: String)? {
        for candidate in candidates(home: home, pathFolders: pathFolders, excluding: installation.baseDirectory) {
            if let (_, version) = try? await installation.customRuntime(executable: candidate) { return (candidate, version) }
        }
        return nil
    }

    private static func subfolders(of url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest Python version first
    }
}
