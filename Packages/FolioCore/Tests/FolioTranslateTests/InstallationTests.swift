import Foundation
import Testing
@testable import FolioTranslate

@Suite struct InstallationTests {
    /// Creates the files `status()` looks at.
    func fakeInstall(_ layout: TranslatorLayout, marker: Bool = true, python: Bool = true, distInfo: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: layout.toolPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        if python {
            try "#!/bin/sh\n".write(to: layout.toolPython, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.toolPython.path)
        }
        let site = layout.toolEnvironment.appending(path: "lib/python3.12/site-packages")
        try fm.createDirectory(at: site, withIntermediateDirectories: true)
        if distInfo { try fm.createDirectory(at: site.appending(path: "pdf2zh_next-2.9.0.dist-info"), withIntermediateDirectories: true) }
        try fm.createDirectory(at: layout.binDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: layout.executable, withDestinationURL: layout.toolEnvironment.appending(path: "bin/pdf2zh_next"))
        try "#!/bin/sh\n".write(to: layout.toolEnvironment.appending(path: "bin/pdf2zh_next"), atomically: true, encoding: .utf8)
        if marker { try "{}".write(to: layout.marker, atomically: true, encoding: .utf8) }
    }

    @Test func statusOfEmptyDirectory() {
        let temp = TemporaryDirectory()
        #expect(TranslatorInstallation(baseDirectory: temp.url.appending(path: "missing")).status() == .notInstalled)
        #expect(TranslatorInstallation(baseDirectory: temp.url).status() == .notInstalled)
        #expect(throws: TranslatorInstallError.notInstalled) { try TranslatorInstallation(baseDirectory: temp.url).runtime() }
    }

    @Test func statusOfCompleteInstallation() throws {
        let temp = TemporaryDirectory()
        let installation = TranslatorInstallation(baseDirectory: temp.url)
        try fakeInstall(installation.layout)
        #expect(installation.status() == .installed(version: "2.9.0", executableURL: installation.layout.executable))
        let runtime = try installation.runtime()
        #expect(runtime.mode == .driver(python: installation.layout.toolPython))
        #expect(runtime.redirectsHome)
    }

    @Test func brokenInstallations() throws {
        let unfinished = TemporaryDirectory()
        try fakeInstall(TranslatorLayout(base: unfinished.url), marker: false)
        #expect(TranslatorInstallation(baseDirectory: unfinished.url).status() == .broken(reason: "The last installation didn't finish"))

        let noPython = TemporaryDirectory()
        try fakeInstall(TranslatorLayout(base: noPython.url), python: false)
        #expect(TranslatorInstallation(baseDirectory: noPython.url).status() == .broken(reason: "The Python environment is missing"))

        let noPackage = TemporaryDirectory()
        try fakeInstall(TranslatorLayout(base: noPackage.url), distInfo: false)
        #expect(TranslatorInstallation(baseDirectory: noPackage.url).status() == .broken(reason: "The pdf2zh_next package is missing"))
    }

    @Test func uninstallKeepsLogsAndHandlesReadOnlyFiles() throws {
        let temp = TemporaryDirectory()
        let installation = TranslatorInstallation(baseDirectory: temp.url)
        try fakeInstall(installation.layout)
        let fm = FileManager.default
        try fm.createDirectory(at: installation.layout.logsDirectory, withIntermediateDirectories: true)
        try "log".write(to: installation.layout.logsDirectory.appending(path: "install.log"), atomically: true, encoding: .utf8)
        let readOnlyDir = installation.layout.cacheDirectory.appending(path: "archive-v0/abc")
        try fm.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        try "x".write(to: readOnlyDir.appending(path: "f"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)

        try installation.uninstall()
        #expect(installation.status() == .notInstalled)
        #expect(try fm.contentsOfDirectory(atPath: temp.url.path) == ["logs"])
    }

    @Test func defaultBaseDirectory() {
        #expect(TranslatorInstallation.defaultBaseDirectory.path.hasSuffix("Library/Application Support/Folio/Translator"))
    }

    @Test func uvEnvironmentIsExplicit() {
        let layout = TranslatorLayout(base: URL(fileURLWithPath: "/base"))
        let env = EngineEnvironment.uv(layout: layout, cacheDirectory: URL(fileURLWithPath: "/cache"))
        #expect(env["UV_TOOL_DIR"] == "/base/tools")
        #expect(env["UV_TOOL_BIN_DIR"] == "/base/bin")
        #expect(env["UV_PYTHON_INSTALL_DIR"] == "/base/python")
        #expect(env["UV_CACHE_DIR"] == "/cache")
        #expect(env["UV_PYTHON_PREFERENCE"] == "only-managed")
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["FOLIO_TRANSLATOR_HOME"] == "/base/home")
        #expect(env["TMPDIR"] == "/base/tmp/")
        #expect(env["PYTHONPATH"] == nil && env["VIRTUAL_ENV"] == nil && env["PYTHONHOME"] == nil)
    }

    @Test func uvProgressParserFollowsRealOutput() {
        // Captured from `uv tool install --python 3.12 pdf2zh-next==2.9.0 --with "bitstring<5"` (uv 0.12.6, empty cache).
        let lines = [
            "Downloading cpython-3.12.14-macos-aarch64-none (download) (23.8MiB)",
            " Downloaded cpython-3.12.14-macos-aarch64-none (download)",
            "Resolved 133 packages in 9.57s",
            "Downloading pillow (4.5MiB)", "Downloading gradio (51.8MiB)",
            " Downloaded pillow", " Downloaded gradio",
            "Prepared 133 packages in 1m 51s",
            "Installed 133 packages in 206ms",
            " + aiofiles==24.1.0",
            "Installed 3 executables: pdf2zh, pdf2zh2, pdf2zh_next",
        ]
        var parser = UVInstallProgressParser()
        var fractions: [Double] = []
        for line in lines { if let update = parser.consume(line) { fractions.append(update.fraction) } }
        #expect(fractions == fractions.sorted(), "monotonic: \(fractions)")
        #expect(fractions.first == 0.02)
        #expect(fractions.last == 1)
        #expect(parser.announced == 2 && parser.downloaded == 2)
    }

    @Test func pythonInterpreterFromEntryPoints() throws {
        let temp = TemporaryDirectory()
        // 1. venv layout: python next to the entry point (through a symlink).
        let venvPython = try temp.script("venv/bin/python", "")
        _ = try temp.script("venv/bin/pdf2zh_next", "")
        try FileManager.default.createDirectory(at: temp.url.appending(path: "bin"), withIntermediateDirectories: true)
        let link = temp.url.appending(path: "bin/pdf2zh_next")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: temp.url.appending(path: "venv/bin/pdf2zh_next"))
        #expect(TranslatorRuntime.pythonInterpreter(forEntryPoint: link)?.resolvingSymlinksInPath() == venvPython.resolvingSymlinksInPath())

        // 2. uv's sh trampoline for long paths.
        let python = try temp.script("py with space/python3.12", "")
        let trampoline = temp.url.appending(path: "tramp/pdf2zh_next")
        try FileManager.default.createDirectory(at: trampoline.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n'''exec' '\(python.path)' \"$0\" \"$@\"\n' '''\nimport sys\n".write(to: trampoline, atomically: true, encoding: .utf8)
        #expect(TranslatorRuntime.pythonInterpreter(forEntryPoint: trampoline) == python)

        // 3. Plain shebang.
        let plain = temp.url.appending(path: "plain/pdf2zh_next")
        try FileManager.default.createDirectory(at: plain.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!\(python.path.replacingOccurrences(of: " ", with: "_")) \nx".write(to: plain, atomically: true, encoding: .utf8)
        #expect(TranslatorRuntime.pythonInterpreter(forEntryPoint: plain) == nil, "non-existent interpreter")
    }

    @Test func customExecutableValidation() async throws {
        let temp = TemporaryDirectory()
        let installation = TranslatorInstallation(baseDirectory: temp.url.appending(path: "base"))
        await #expect(throws: TranslatorInstallError.self) {
            _ = try await installation.customRuntime(executable: temp.url.appending(path: "nope"))
        }
        let fake = try temp.script("bin/pdf2zh_next", #"[ "$1" = "--version" ] && echo "pdf2zh-next version: 2.9.0""#)
        let (runtime, version) = try await installation.customRuntime(executable: fake)
        #expect(version == "2.9.0")
        #expect(runtime.mode == .cli(executable: fake))
        #expect(!runtime.redirectsHome)

        let broken = try temp.script("bin2/pdf2zh_next", "echo 'ImportError: cannot import name BitStream' >&2; exit 1")
        await #expect(throws: TranslatorInstallError.self) {
            _ = try await installation.customRuntime(executable: broken)
        }
    }

    @Test func driverScriptIsWrittenOnce() throws {
        let temp = TemporaryDirectory()
        let url = try DriverScript.install(into: temp.url)
        let first = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(try String(contentsOf: url, encoding: .utf8) == DriverScript.source)
        let again = try DriverScript.install(into: temp.url)
        #expect(again == url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == first)
        #expect(DriverScript.source.contains("do_translate_async_stream"))
        #expect(DriverScript.source.contains("if __name__ == \"__main__\":"), "required for multiprocessing spawn")
    }
}

@Suite struct AppleTranslatorTests {
    @Test func languageMapping() {
        #expect(AppleSystemTranslator.language(forCode: "zh").maximalIdentifier.hasPrefix("zh-Hans"))
        #expect(AppleSystemTranslator.language(forCode: "zh-CN").maximalIdentifier.hasPrefix("zh-Hans"))
        #expect(AppleSystemTranslator.language(forCode: "zh_TW").maximalIdentifier.hasPrefix("zh-Hant"))
        #expect(AppleSystemTranslator.language(forCode: "en").languageCode?.identifier == "en")
        #expect(AppleSystemTranslator.language(forCode: "ja").languageCode?.identifier == "ja")
    }

    @Test func commandLineUsageErrors() async throws {
        let temp = TemporaryDirectory()
        let outURL = temp.url.appending(path: "out"), errURL = temp.url.appending(path: "err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        #expect(await AppleSystemTranslator.runCommandLine(arguments: ["--from", "en"], output: out, errorOutput: err) == 2)
        #expect(await AppleSystemTranslator.runCommandLine(arguments: ["--bogus"], output: out, errorOutput: err) == 2)
        #expect(await AppleSystemTranslator.runCommandLine(arguments: ["--help"], output: out, errorOutput: err) == 0)
        try out.close(); try err.close()
        #expect(try String(contentsOf: errURL, encoding: .utf8).contains("usage: folio-apple-translate"))
    }
}
