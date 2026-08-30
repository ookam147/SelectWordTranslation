import Foundation
import Security

protocol CredentialStore: Sendable {
    func apiKey(for account: String) throws -> String?
    func setAPIKey(_ apiKey: String, for account: String) throws
    func removeAPIKey(for account: String) throws
}

enum CredentialStoreError: LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}

final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    private let service: String

    init(service: String = "com.zwalking.SelectWordTranslation.api-keys") {
        self.service = service
    }

    func apiKey(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setAPIKey(_ apiKey: String, for account: String) throws {
        if apiKey.isEmpty {
            try removeAPIKey(for: account)
            return
        }
        let data = Data(apiKey.utf8)
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            let status = SecItemAdd(insertion as CFDictionary, nil)
            guard status == errSecSuccess else { throw CredentialStoreError.unexpectedStatus(status) }
        } else if updateStatus != errSecSuccess {
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }
    }

    func removeAPIKey(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
}

enum CredentialMigrator {
    static let migrationKey = "credentialMigrationV2Completed"

    static func migrateIfNeeded(
        defaults: UserDefaults,
        store: CredentialStore,
        configuration: TranslationConfiguration,
        presets: [APIPreset]
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        let genericKey = defaults.string(forKey: "apiKey") ?? ""

        var migrationFailed = false
        for preset in presets {
            guard (try? store.apiKey(for: preset.id)) == nil else { continue }
            let unstableLegacyKey = "apiKey_\(preset.baseURL.hashValue)"
            let legacy = defaults.string(forKey: unstableLegacyKey)
                ?? (preset.baseURL == configuration.baseURL ? genericKey : nil)
            if let legacy, !legacy.isEmpty {
                do {
                    try store.setAPIKey(legacy, for: preset.id)
                    defaults.removeObject(forKey: unstableLegacyKey)
                } catch {
                    migrationFailed = true
                    continue
                }
            }
        }

        if !genericKey.isEmpty {
            let account = configuration.providerID
            if (try? store.apiKey(for: account)) == nil {
                do { try store.setAPIKey(genericKey, for: account) }
                catch { migrationFailed = true }
            }
            if let stored = try? store.apiKey(for: account), !stored.isEmpty {
                defaults.removeObject(forKey: "apiKey")
            }
        }
        if !migrationFailed { defaults.set(true, forKey: migrationKey) }
    }
}
