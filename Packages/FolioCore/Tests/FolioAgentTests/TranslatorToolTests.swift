import Foundation
import Testing
@testable import FolioAgent

/// `set_pdf2zh_next_path`: verified before it is saved where Folio reads it.
@Suite(.serialized) struct TranslatorToolTests {
    @Test func setsOnlyAWorkingEngine() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "folio-pdf2zh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "bin"), withIntermediateDirectories: true)
        let engine = folder.appending(path: "bin/pdf2zh_next")
        try "#!/bin/sh\n[ \"$1\" = \"--version\" ] && echo \"pdf2zh-next version: 2.9.0\"\n".write(to: engine, atomically: true, encoding: .utf8)
        let other = folder.appending(path: "bin/python")
        try "#!/bin/sh\necho 'Python 3.12.1'\n".write(to: other, atomically: true, encoding: .utf8)
        for file in [engine, other] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }

        let suite = "folio-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        LibraryToolbox.translatorPreferences = { UserDefaults(suiteName: suite) }
        defer {
            defaults.removePersistentDomain(forName: suite)
            LibraryToolbox.translatorPreferences = { AgentConfiguration.preferences() }
        }
        let toolbox = LibraryToolbox(configurationSource: { AgentConfiguration(libraryRoot: folder.appending(path: "library")) })

        await #expect(throws: ToolError.self) { _ = try await toolbox.call("set_pdf2zh_next_path", arguments: ["path": .string(other.path)]) }
        #expect(defaults.string(forKey: AgentConfiguration.translatorPathKey) == nil, "a program that is not pdf2zh_next is refused")

        let result = try await toolbox.call("set_pdf2zh_next_path", arguments: ["path": .string(engine.path)])
        #expect(result["version"]?.stringValue == "2.9.0")
        #expect(defaults.string(forKey: AgentConfiguration.translatorPathKey) == engine.standardizedFileURL.path)
        // Works without a library: these tools only touch Folio's preferences.
        let found = try await toolbox.call("find_pdf2zh_next", arguments: .null)
        #expect(found["in_use"]?["version"]?.stringValue == "2.9.0")
        #expect(found["searched"]?.stringValue?.isEmpty == false)
    }

    @Test func toolsAreListedAndDocumented() {
        #expect(ToolCatalog.available(allowWrites: false).contains { $0.name == "find_pdf2zh_next" })
        #expect(ToolCatalog.available(allowWrites: false).contains { $0.name == "set_pdf2zh_next_path" })
        let skill = FolioSkill.markdown(cliPath: "/Applications/Folio.app/Contents/MacOS/folio-cli")
        #expect(skill.contains("find_pdf2zh_next") && skill.contains("set_pdf2zh_next_path"))
    }
}
