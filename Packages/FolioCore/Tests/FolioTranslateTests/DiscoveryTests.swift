import Foundation
import Testing
@testable import FolioTranslate

@Suite struct DiscoveryTests {
    let ok = #"[ "$1" = "--version" ] && echo "pdf2zh-next version: 2.9.0""#

    @Test func findsUsualInstallLocationsWithoutDuplicates() throws {
        let temp = TemporaryDirectory()
        let home = temp.url.appending(path: "home")
        let uv = try temp.script("home/.local/share/uv/tools/pdf2zh-next/bin/pdf2zh_next", ok)
        // uv links the command into ~/.local/bin: the same program, listed once.
        try FileManager.default.createDirectory(at: home.appending(path: ".local/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".local/bin/pdf2zh_next"), withDestinationURL: uv)
        let conda = try temp.script("home/miniconda3/envs/translate/bin/pdf2zh_next", ok)
        let onPath = try temp.script("tools/pdf2zh-next", ok)
        // Folio's own copy is never "the user's".
        let base = temp.url.appending(path: "home/Library/Application Support/Folio/Translator")
        try temp.script("home/Library/Application Support/Folio/Translator/tools/bin/pdf2zh_next", ok)
        let found = TranslatorDiscovery.candidates(home: home, pathFolders: [temp.url.appending(path: "tools").path,
                                                                             base.appending(path: "tools/bin").path],
                                                   excluding: base)
        #expect(found.first == onPath, "the shell's PATH comes first")
        #expect(found.contains(home.appending(path: ".local/bin/pdf2zh_next")) && !found.contains(uv))
        // Directory listings spell the temporary folder /private/var: compare real paths.
        #expect(found.map { $0.resolvingSymlinksInPath().path }.contains(conda.resolvingSymlinksInPath().path))
        #expect(!found.contains { $0.path.contains("Folio/Translator") })
    }

    @Test func discoverSkipsCommandsThatDoNotRun() async throws {
        let temp = TemporaryDirectory()
        let home = temp.url.appending(path: "home")
        try temp.script("first/pdf2zh_next", "echo 'ModuleNotFoundError: babeldoc' >&2; exit 1")
        let good = try temp.script("home/.local/bin/pdf2zh_next", ok)
        let installation = TranslatorInstallation(baseDirectory: temp.url.appending(path: "base"))
        let result = await TranslatorDiscovery.discover(installation: installation, home: home,
                                                        pathFolders: [temp.url.appending(path: "first").path])
        #expect(result?.executable == good && result?.version == "2.9.0")
        let none = await TranslatorDiscovery.discover(installation: installation, home: temp.url.appending(path: "empty"),
                                                      pathFolders: [temp.url.appending(path: "first").path])
        #expect(none == nil || none?.executable.path.hasPrefix("/opt/homebrew") == true || none?.executable.path.hasPrefix("/usr/local") == true,
                "only a real system-wide install could be found")
    }
}
