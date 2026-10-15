import Foundation

/// A saved configuration of one translation service (TRANS-03): its Base URL, model and other fields, with its
/// keys in the Keychain. Users keep several — say two OpenAI-compatible providers — and switch with one click.
///
/// The engine keeps reading the service's current values (`translationFields` and the service's Keychain items);
/// choosing a profile copies it there, and editing a field while a profile is chosen writes back into it.
public struct TranslationProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var serviceID: String
    /// Non-secret values by CLI option.
    public var fields: [String: String]

    public init(id: String = UUID().uuidString, name: String, serviceID: String, fields: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.serviceID = serviceID
        self.fields = fields
    }

    /// The Keychain "service id" this profile's keys are stored under.
    public var secretOwner: String { "profile.\(id)" }
}

/// Where keys live: the Keychain (`SecretStore`), or memory in tests.
public protocol SecretStoring: Sendable {
    func get(serviceID: String, option: String) throws -> String?
    func set(_ value: String, serviceID: String, option: String) throws
    func delete(serviceID: String, option: String) throws
}

extension SecretStore: SecretStoring {}

public enum TranslationProfiles {
    /// Services with something to configure beyond advanced options: an address, a key or a model.
    public static func supportsProfiles(_ service: TranslationService) -> Bool { service.fields.contains { !$0.isAdvanced } }

    /// A profile holding the service's current values, keys copied into the profile's own Keychain items.
    public static func capture(name: String, service: TranslationService, fields: [String: String],
                               secrets: some SecretStoring) throws -> TranslationProfile {
        let profile = TranslationProfile(name: name, serviceID: service.id, fields: fields.filter { !$0.value.isEmpty })
        for field in service.secretFields {
            if let value = try secrets.get(serviceID: service.id, option: field.option), !value.isEmpty {
                try secrets.set(value, serviceID: profile.secretOwner, option: field.option)
            }
        }
        return profile
    }

    /// Makes `profile` the service's current configuration: returns the fields to use and puts its keys in place
    /// (a key the profile does not have is cleared, so nothing leaks over from the previous provider).
    public static func apply(_ profile: TranslationProfile, service: TranslationService,
                             secrets: some SecretStoring) throws -> [String: String] {
        for field in service.secretFields {
            if let value = try secrets.get(serviceID: profile.secretOwner, option: field.option), !value.isEmpty {
                try secrets.set(value, serviceID: service.id, option: field.option)
            } else {
                try secrets.delete(serviceID: service.id, option: field.option)
            }
        }
        return profile.fields
    }

    /// Keeps a profile's key in step with an edit of the current one.
    public static func recordSecret(_ value: String, option: String, in profile: TranslationProfile,
                                    secrets: some SecretStoring) throws {
        if value.isEmpty {
            try secrets.delete(serviceID: profile.secretOwner, option: option)
        } else {
            try secrets.set(value, serviceID: profile.secretOwner, option: option)
        }
    }

    /// Removes a profile's keys (the profile itself is dropped by the caller).
    public static func deleteSecrets(of profile: TranslationProfile, service: TranslationService,
                                     secrets: some SecretStoring) throws {
        for field in service.secretFields { try secrets.delete(serviceID: profile.secretOwner, option: field.option) }
    }

    /// A name for a new profile: the provider's host from its Base URL ("api.deepseek.com"), else the service's
    /// name; numbered when taken.
    public static func suggestedName(service: TranslationService, fields: [String: String], existing: [TranslationProfile]) -> String {
        let urlOption = service.fields.first { $0.kind == .url }?.option
        let host = urlOption.flatMap { fields[$0] }.flatMap { URL(string: $0)?.host() }
        let base = host ?? service.displayName
        let taken = Set(existing.filter { $0.serviceID == service.id }.map(\.name))
        guard taken.contains(base) else { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) }!
    }
}
