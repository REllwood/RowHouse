import Foundation
import Security

/// Where the Claude API key and default model live on this Mac. The key is kept in the login
/// Keychain; the `ANTHROPIC_API_KEY` environment variable is used when no key has been saved.
public enum AIConfiguration {
    public static let keychainService = "com.rellwood.RowHouse.anthropic"
    public static let keychainAccount = "api-key"
    public static let defaultModelKey = "RowHouse.ai.defaultModel"
    public static let environmentVariable = "ANTHROPIC_API_KEY"

    public enum KeychainError: LocalizedError, Equatable {
        case status(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "The Keychain couldn't store the key: \(message)"
            }
        }
    }

    /// The model used when an AI field doesn't choose its own.
    public static var defaultModel: String {
        get {
            let stored = UserDefaults.standard.string(forKey: defaultModelKey)?.trimmingCharacters(in: .whitespaces)
            return stored?.isEmpty == false ? stored! : AIModel.default.rawValue
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultModelKey) }
    }

    public static var environmentAPIKey: String? {
        let value = ProcessInfo.processInfo.environment[environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    /// The saved key, or the environment's when none is saved.
    public static func resolvedAPIKey() -> String? {
        savedAPIKey() ?? environmentAPIKey
    }

    /// A service using the resolved key and default model.
    public static func makeService(session: URLSession? = nil) throws -> AIService {
        guard let key = resolvedAPIKey() else { throw AIServiceError.missingAPIKey }
        return AIService(apiKey: key, defaultModel: defaultModel, session: session)
    }

    // MARK: - Keychain

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    public static func savedAPIKey() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { return nil }
        return key
    }

    public static var hasSavedAPIKey: Bool { savedAPIKey() != nil }

    public static func saveAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey()
            return
        }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrLabel as String] = "RowHouse Anthropic API key"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
