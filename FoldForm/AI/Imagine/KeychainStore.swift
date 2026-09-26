import Foundation
import Security

protocol KeyProviding: Sendable {
    func apiKey() throws -> String?
}

struct KeychainStore: KeyProviding {
    var account: String = "nvidia-nim"
    private let service = "com.ishaanashok.FoldForm.imagine"

    func apiKey() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.status(status)
        }
        return key
    }

    func save(_ key: String) throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KeychainError.emptyKey }
        try delete()
        var query = baseQuery()
        query[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum KeychainError: Error {
    case status(OSStatus)
    case emptyKey
}
