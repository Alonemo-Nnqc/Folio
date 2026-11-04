import Foundation

/// Names of translated files (TRANS-05): what they are and who translated them, so several versions of one paper
/// tell themselves apart — "论文（简体中文译文 · DeepSeek · deepseek-chat）.pdf", "论文（双语对照 · Google）.pdf";
/// in English "Paper (Simplified Chinese translation · DeepSeek · deepseek-chat).pdf".
public enum TranslationNaming {
    /// Who translated: the configuration's name when one is in use, else the service's name; and the model.
    public struct Provider: Sendable, Hashable {
        public var name: String
        public var model: String?

        public init(name: String, model: String?) {
            self.name = name
            self.model = model
        }

        /// From the service, its current values and the configuration in use.
        public init(service: TranslationService, fields: [String: String], profileName: String?) {
            name = profileName ?? TranslationNaming.name(of: service)
            let modelField = service.fields.first { $0.title == TranslationServiceCatalog.modelFieldTitle }
            model = modelField.flatMap { field in
                (fields[field.option].flatMap { $0.isEmpty ? nil : $0 } ?? field.defaultValue)
            }
        }

        /// "DeepSeek · deepseek-chat", or the name alone when there is no model.
        public var label: String {
            guard let model, !model.isEmpty, model.caseInsensitiveCompare(name) != .orderedSame else { return name }
            return "\(name) · \(model)"
        }
    }

    /// A service's name for file names: without notes such as "（免费）" / " (free)", which belong to the picker.
    public static func name(of service: TranslationService) -> String {
        service.displayName.replacingOccurrences(of: #"\s*[（(][^）)]*[）)]$"#, with: "", options: .regularExpression)
    }

    /// The name of the service with this id ("google" → "Google"), including services of pdf2zh (whose Zotero plugin
    /// names files by them) that Folio does not offer; nil for one Folio doesn't know.
    public static func serviceName(id: String) -> String? {
        let id = id.lowercased()
        if let service = TranslationServiceCatalog.service(id: id) { return name(of: service) }
        return legacyNames[id]
    }

    static let legacyNames: [String: String] = [
        "siliconflowfree": String(localized: "SiliconFlow 免费", bundle: .module), "xinference": "Xinference",
        "anythingllm": "AnythingLLM", "dify": "Dify",
    ]

    /// The base name (no extension) for a translated file. `existing` are the base names of the item's files: a
    /// name already taken (the same provider and model again) gets the time of translation, not a number.
    public static func baseName(original: String, kind: TranslationKindName, language: String, provider: Provider,
                                existing: Set<String>, date: Date = Date()) -> String {
        let what = kind == .mono ? String(localized: "\(language)译文", bundle: .module) : String(localized: "双语对照", bundle: .module)
        let name = String(localized: "\(original)（\(what) · \(provider.label)）", bundle: .module)
        guard existing.contains(name) else { return name }
        // No colons: Finder shows them as slashes.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = String(localized: "M月d日 HH.mm", bundle: .module)
        var time = formatter.string(from: date)
        var timed = String(localized: "\(original)（\(what) · \(provider.label) · \(time)）", bundle: .module)
        if existing.contains(timed) {
            formatter.dateFormat = String(localized: "M月d日 HH.mm.ss", bundle: .module)
            time = formatter.string(from: date)
            timed = String(localized: "\(original)（\(what) · \(provider.label) · \(time)）", bundle: .module)
        }
        return timed
    }

    /// The two kinds of output (FolioCore's TranslationKind, without depending on it).
    public enum TranslationKindName: Sendable { case mono, dual }
}
