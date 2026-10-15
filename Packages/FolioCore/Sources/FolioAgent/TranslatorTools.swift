import Foundation
import FolioTranslate

/// `find_pdf2zh_next` and `set_pdf2zh_next_path`: an agent can find the user's own pdf2zh_next — with Folio's
/// search, or its own shell when that finds nothing — and make Folio translate with it.
extension LibraryToolbox {
    /// Where the setting lives; tests point it at a scratch suite.
    nonisolated(unsafe) static var translatorPreferences: () -> UserDefaults? = { AgentConfiguration.preferences() }

    func findPDF2zhNext() async -> JSONValue {
        let installation = TranslatorInstallation()
        let preferences = Self.translatorPreferences()
        var configured: JSONValue = .null
        if let path = preferences?.string(forKey: AgentConfiguration.translatorPathKey), !path.isEmpty {
            do {
                let version = try await installation.customRuntime(executable: URL(filePath: path)).version
                configured = ["path": .string(path), "version": .string(version)]
            } catch {
                configured = ["path": .string(path), "error": .string(error.localizedDescription)]
            }
        }
        let survey = await TranslatorDiscovery.survey(installation: installation, pathFolders: ShellEnvironment.loginPATH())
        let working = survey.compactMap { entry -> JSONValue? in
            guard case .success(let version) = entry.result else { return nil }
            return ["path": .string(entry.executable.path), "version": .string(version)]
        }
        let failing = survey.compactMap { entry -> JSONValue? in
            guard case .failure(let error) = entry.result else { return nil }
            return ["path": .string(entry.executable.path), "error": .string(error.localizedDescription)]
        }
        let next = working.isEmpty
            ? "Nothing working was found. Search further with your shell (the skill lists commands), or install it: uv tool install pdf2zh-next. Then call set_pdf2zh_next_path."
            : "Ask the user which one to use if there are several, then call set_pdf2zh_next_path with its path."
        return [
            "in_use": configured == .null ? .string("Folio's built-in engine") : configured,
            "found": .array(working),
            "not_working": .array(failing),
            "searched": .string(TranslatorDiscovery.searchedPlaces),
            "next_step": .string(next),
        ]
    }

    func setPDF2zhNextPath(_ args: JSONValue) async throws -> JSONValue {
        guard let raw = args["path"]?.stringValue, !raw.isEmpty else { throw ToolError("Missing path.") }
        let url = URL(filePath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        let version: String
        do {
            version = try await TranslatorInstallation().customRuntime(executable: url).version
        } catch {
            throw ToolError("Folio cannot use \(url.path): \(error.localizedDescription)")
        }
        guard let preferences = Self.translatorPreferences() else { throw ToolError("Cannot reach Folio's preferences.") }
        preferences.set(url.path, forKey: AgentConfiguration.translatorPathKey)
        preferences.synchronize()
        DistributedNotificationCenter.default().postNotificationName(AgentConfiguration.preferencesDidChange, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
        return ["path": .string(url.path), "version": .string(version),
                "message": .string("Folio now translates with pdf2zh_next \(version) at \(url.path) (设置 ▸ 翻译).")]
    }
}
