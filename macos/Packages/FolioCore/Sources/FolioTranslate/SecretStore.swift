import Foundation
import Security

/// Keychain storage for translation service secrets (generic passwords).
///
/// Items use service `com.nnqc.Folio.translation` and account
/// `<serviceId>.<option>`, e.g. `openai.--openai-api-key`.
public struct SecretStore: Sendable {
    public static let defaultService = "com.nnqc.Folio.translation"

    public let service: String

    public init(service: String = SecretStore.defaultService) {
        self.service = service
    }

    public struct KeychainError: Error, LocalizedError, Sendable, Equatable {
        public let status: OSStatus
        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return String(localized: "钥匙串操作失败：\(message)", bundle: .module)
        }
    }

    public static func account(serviceID: String, option: String) -> String {
        "\(serviceID).\(option)"
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func get(serviceID: String, option: String) throws -> String? {
        var query = query(Self.account(serviceID: serviceID, option: option))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    /// Stores `value`; an empty value deletes the item.
    public func set(_ value: String, serviceID: String, option: String) throws {
        guard !value.isEmpty else {
            try delete(serviceID: serviceID, option: option)
            return
        }
        let account = Self.account(serviceID: serviceID, option: option)
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(account)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = String(localized: "Folio 翻译：\(account)", bundle: .module)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(serviceID: String, option: String) throws {
        let status = SecItemDelete(query(Self.account(serviceID: serviceID, option: option)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// All stored secrets of a service, keyed by CLI option (for `TranslationRequest.secrets`).
    public func secrets(for service: TranslationService) throws -> [String: String] {
        var values: [String: String] = [:]
        for field in service.secretFields {
            if let value = try get(serviceID: service.id, option: field.option) { values[field.option] = value }
        }
        return values
    }
}
