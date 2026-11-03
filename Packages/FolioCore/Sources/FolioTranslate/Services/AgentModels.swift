import Foundation

/// Models a local agent can be asked to use: what its own configuration lists, plus its usual aliases.
public enum AgentModels {
    public static func models(for agent: LocalAgent, executable: URL?) async -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var models: [String] = []
        switch agent {
        case .claude:
            models = ["haiku", "sonnet", "opus"]
        case .codex:
            // ~/.codex/config.toml names the model and, optionally, a catalog of the provider's models.
            let config = (try? String(contentsOf: home.appending(path: ".codex/config.toml"), encoding: .utf8)) ?? ""
            if let model = value("model", in: config) { models.append(model) }
            if let catalog = value("model_catalog_json", in: config) {
                let url = catalog.hasPrefix("/") ? URL(filePath: catalog) : home.appending(path: ".codex/\(catalog)")
                if let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = object["models"] as? [[String: Any]] {
                    models += list.compactMap { $0["slug"] as? String }
                }
            }
        case .gemini:
            models = ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite"]
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
        }
        var seen: Set<String> = []
        return models.filter { !$0.isEmpty && seen.insert($0).inserted }
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
