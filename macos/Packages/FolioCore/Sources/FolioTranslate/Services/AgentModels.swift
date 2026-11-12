import Foundation

/// Models a local agent can be asked to use: what its own configuration lists, plus its usual aliases.
public enum AgentModels {
    public static func models(for agent: LocalAgent, executable: URL?) async -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var models: [String] = []
        switch agent {
        case .workbuddy:
            // What WorkBuddy's command line lists in its help.
            models = ["auto", "glm-5.1", "glm-5.0", "glm-5.0-turbo", "glm-4.7", "kimi-k2.5", "minimax-m2.7", "deepseek-v3-2-volc"]
        case .claude:
            models = ["haiku", "sonnet", "opus"]
        case .codex:
            // ~/.codex/config.toml names the model and, optionally, a catalog of the provider's models.
            let config = (try? String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)) ?? ""
            if let model = value("model", in: config) { models.append(model) }
            // The list Codex itself keeps of what this account can use.
            if let data = try? Data(contentsOf: home.appending(path: ".codex/models_cache.json")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = object["models"] as? [[String: Any]] {
                models += list.filter { ($0["visibility"] as? String) != "hide" }.compactMap { $0["slug"] as? String }
            }
            if let catalog = value("model_catalog_json", in: config) {
                let url = catalog.hasPrefix("/") ? URL(filePath: catalog) : home.appending(path: ".codex/\(catalog)")
                if let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = object["models"] as? [[String: Any]] {
                    models += list.compactMap { $0["slug"] as? String }
                }
            }
        case .gemini:
            // The models this version of Gemini CLI accepts, as its own code names them; a known list if that cannot be read.
            models = ["auto"] + (geminiModels(executable: executable) ?? [
                "gemini-3.1-pro-preview", "gemini-3-pro-preview", "gemini-3.5-flash", "gemini-3-flash-preview", "gemini-3.1-flash-lite",
                "gemini-2.5-pro", "gemini-2.5-flash",
            ])
            if let data = try? Data(contentsOf: home.appending(path: ".gemini/settings.json")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let name = (object["model"] as? [String: Any])?["name"] as? String { models.insert(name, at: 0) }
                else if let name = object["model"] as? String { models.insert(name, at: 0) }
            }
        case .qwen:
            models = ["qwen3-coder-plus", "qwen3-coder-flash"]
        case .opencode:
            if let executable, let output = try? await LocalProcess.run([executable.path, "models"], input: "", timeout: 20) {
                models = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.contains("/") && !$0.contains(" ") }
            }
        case .cursor:
            if let executable, let output = try? await LocalProcess.run([executable.path, "models"], input: "", timeout: 20) {
                models = output.split(whereSeparator: \.isNewline).compactMap { line in
                    line.split(separator: " ").first.map(String.init)
                }.filter { $0.range(of: #"^[a-z0-9][a-z0-9.\-]+$"#, options: .regularExpression) != nil }
            }
            if models.isEmpty { models = ["auto"] }
        case .grok:
            // "  - grok-4.6", "  * grok-4.7 (default)"
            models = await lines(executable, ["models"]).compactMap { line in
                line.firstMatch(of: /^\s*[-*]\s+(\S+)/).map { String($0.output.1) }
            }
        case .antigravity:
            // One model per line: its id, a tab, its name.
            models = await lines(executable, ["models"]).compactMap { line in
                guard line.contains("\t") else { return nil }
                return line.split(separator: "\t").first.map(String.init)
            }
        case .pi:
            // A table: provider, model, then figures.
            models = await lines(executable, ["--list-models"]).dropFirst().compactMap { line in
                let columns = line.split(whereSeparator: \.isWhitespace)
                return columns.count >= 2 ? "\(columns[0])/\(columns[1])" : nil
            }
        case .openclaw:
            if let executable, let output = try? await LocalProcess.run([executable.path, "models", "list", "--json"], input: "", timeout: 30),
               let object = LLMBatch.jsonObject(in: output), let list = object["models"] as? [[String: Any]] {
                models = list.compactMap { $0["key"] as? String ?? $0["id"] as? String }
            }
        case .hermes:
            // ~/.hermes/config.yaml: the model it uses unless told otherwise.
            let config = (try? String(contentsOf: home.appending(path: ".hermes/config.yaml"), encoding: .utf8)) ?? ""
            var inModel = false
            for line in config.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("model:") { inModel = true; continue }
                if inModel, !line.hasPrefix(" ") { break }
                if inModel, let match = line.firstMatch(of: /^\s+default:\s*"?([^"\s#]+)/) { models.append(String(match.output.1)) }
            }
        case .droid, .copilot, .kiro, .cline, .kimi, .amp, .goose, .deepseek:
            // No listing to read: the model field stays free text, and empty means the agent's own default.
            break
        }
        var seen: Set<String> = []
        return models.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Codex's own list of what each model accepts: its thinking levels and the one it uses by default.
    public static func codexLevels(model: String?) -> (levels: [String], usual: String?)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = (try? String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)) ?? ""
        guard let name = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? value("model", in: config),
              let data = try? Data(contentsOf: home.appending(path: ".codex/models_cache.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (object["models"] as? [[String: Any]])?.first(where: { ($0["slug"] as? String) == name }),
              let listed = entry["supported_reasoning_levels"] as? [Any] else { return nil }
        let levels = listed.compactMap { ($0 as? [String: Any])?["effort"] as? String ?? $0 as? String }
        return (levels, entry["default_reasoning_level"] as? String)
    }

    /// Gemini CLI's model names, read from its installed code (`var DEFAULT_GEMINI_MODEL = "gemini-2.5-pro"` and the like).
    static func geminiModels(executable: URL?) -> [String]? {
        guard let executable else { return nil }
        let real = executable.resolvingSymlinksInPath()
        // …/node_modules/@google/gemini-cli/…: its bundle folder.
        var root = real.deletingLastPathComponent()
        for _ in 0..<4 where !FileManager.default.fileExists(atPath: root.appending(path: "bundle").path) { root.deleteLastPathComponent() }
        let bundle = root.appending(path: "bundle")
        guard let files = try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.pathExtension == "js" {
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("VALID_GEMINI_MODELS") else { continue }
            let names = text.matches(of: /var (?:PREVIEW|DEFAULT|SECONDARY)_GEMINI[_A-Z0-9]*_MODEL = "(gemini-[^"]+)"/).map { String($0.output.1) }
            let usable = names.filter { !$0.contains("embedding") && !$0.contains("customtools") }
            var seen: Set<String> = []
            let ordered = usable.filter { seen.insert($0).inserted }.sorted { a, b in
                // Newest first: by version number, then pro before flash before lite.
                func version(_ m: String) -> Double { Double(m.firstMatch(of: /gemini-(\d+(?:\.\d+)?)/).map { String($0.output.1) } ?? "0") ?? 0 }
                func rank(_ m: String) -> Int { m.contains("pro") ? 0 : m.contains("lite") ? 2 : 1 }
                return version(a) != version(b) ? version(a) > version(b) : rank(a) < rank(b)
            }
            if !ordered.isEmpty { return ordered }
        }
        return nil
    }

    private static func lines(_ executable: URL?, _ arguments: [String]) async -> [String] {
        guard let executable, let output = try? await LocalProcess.run([executable.path] + arguments, input: "", timeout: 30) else { return [] }
        return output.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// `key = "value"` in a TOML file (top level).
    static func value(_ key: String, in toml: String) -> String? {
        for line in toml.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard trimmed.hasPrefix(key), let eq = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            let raw = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
