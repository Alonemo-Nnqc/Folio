import Foundation

/// Names of translated files (TRANS-05): what they are and who translated them, so several versions of one paper
/// tell themselves apart — "论文（简体中文译文 · DeepSeek · deepseek-chat）.pdf", "论文（双语对照 · Google）.pdf".
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
            // Notes such as "（免费）" or "（本地）" belong to the picker, not to file names.
            let serviceName = service.displayName.replacingOccurrences(of: #"（[^）]*）$"#, with: "", options: .regularExpression)
            name = profileName ?? serviceName
            let modelField = service.fields.first { $0.title == "模型" }
            model = modelField.flatMap { field in
                (fields[field.option].flatMap { $0.isEmpty ? nil : $0 } ?? field.defaultValue)
            }
        }

        var label: String {
            guard let model, !model.isEmpty, model.caseInsensitiveCompare(name) != .orderedSame else { return name }
            return "\(name) · \(model)"
        }
    }

    /// The base name (no extension) for a translated file. `existing` are the base names of the item's files: a
    /// name already taken (the same provider and model again) gets the time of translation, not a number.
    public static func baseName(original: String, kind: TranslationKindName, language: String, provider: Provider,
                                existing: Set<String>, date: Date = Date()) -> String {
        let what = kind == .mono ? "\(language)译文" : "双语对照"
        let name = "\(original)（\(what) · \(provider.label)）"
        guard existing.contains(name) else { return name }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH.mm"
        return "\(original)（\(what) · \(provider.label) · \(formatter.string(from: date))）"
    }

    /// The two kinds of output (FolioCore's TranslationKind, without depending on it).
    public enum TranslationKindName: Sendable { case mono, dual }
}
