import FolioTranslate
import Foundation

/// Which translation services can be used on this Mac right now: those set up (a key, an address, saved
/// configurations), the free ones, and the agents installed here. Finding agents asks each for its `--help`, so the
/// answer is kept for a while.
@MainActor
enum ServiceAvailability {
    private static var installedAgents: Set<String>?
    private static var checkedAt = Date.distantPast
    private static var checking: Task<Set<String>, Never>?

    /// Agents found on this Mac (service ids), looked up again when older than `maxAge`.
    static func agents(maxAge: TimeInterval = 10) async -> Set<String> {
        if let installedAgents, Date().timeIntervalSince(checkedAt) < maxAge { return installedAgents }
        if let checking { return await checking.value }
        let task = Task.detached { Set(LocalAgent.installed().map(\.serviceID)) }
        checking = task
        let found = await task.value
        installedAgents = found
        checkedAt = Date()
        checking = nil
        return found
    }

    /// The agents as last found, without waiting (empty until the first lookup).
    static var knownAgents: Set<String> { installedAgents ?? [] }

    /// Services with something entered: fields, a key or saved configurations (agents not included).
    static func configured(settings: AppSettings, secrets: SecretStore) -> Set<String> {
        var result: Set<String> = []
        for service in TranslationServiceCatalog.all {
            if case .agent = service.backend { continue }
            let fields = settings.translationFields[service.id] ?? [:]
            let hasFields = service.fields.contains { !$0.isSecret && !(fields[$0.option] ?? "").isEmpty && $0.kind != .toggle }
            let hasKey = service.secretFields.contains { ((try? secrets.get(serviceID: service.id, option: $0.option)) ?? nil)?.isEmpty == false }
            let hasProfiles = settings.translationProfiles.contains { $0.serviceID == service.id }
            if hasKey || hasProfiles || (hasFields && service.category != .free) { result.insert(service.id) }
        }
        return result
    }

    /// Services 划词翻译 can use without further setup, in catalog order.
    static func ready(settings: AppSettings, secrets: SecretStore, agents: Set<String>) -> [TranslationService] {
        let configured = configured(settings: settings, secrets: secrets)
        return TranslationServiceCatalog.all.filter { service in
            switch service.category {
            case .free: return true
            case .agent: return agents.contains(service.id)
            case .local:
                if service.id == TranslationServiceCatalog.appleServiceID { return AppleSystemTranslator.isSupportedOnThisSystem }
                return configured.contains(service.id)
            case .llm, .machine: return configured.contains(service.id)
            }
        }
    }
}
