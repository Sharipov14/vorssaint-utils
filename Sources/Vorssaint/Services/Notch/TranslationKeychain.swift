// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Security

/// API keys, one keychain item per account under a feature's service. Keys
/// never touch preferences, so settings backups and exports cannot carry them.
struct SecretKeychain {
    let service: String

    init(suffix: String) {
        service = (Bundle.main.bundleIdentifier ?? "com.vorssaint.utils") + "." + suffix
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func key(for account: String) -> String {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// An empty key removes the item.
    @discardableResult
    func setKey(_ key: String, for account: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(account) }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    func remove(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// The online translators' keys, one per service.
enum TranslationKeychain {
    private static let keychain = SecretKeychain(suffix: "translate")

    static func key(for provider: NotchTranslateProvider) -> String { keychain.key(for: provider.rawValue) }

    @discardableResult
    static func setKey(_ key: String, for provider: NotchTranslateProvider) -> Bool {
        keychain.setKey(key, for: provider.rawValue)
    }

    @discardableResult
    static func remove(_ provider: NotchTranslateProvider) -> Bool { keychain.remove(provider.rawValue) }
}

/// The chat providers' keys, one per provider id.
enum ChatKeychain {
    private static let keychain = SecretKeychain(suffix: "chat")

    static func key(for provider: ChatProvider) -> String { keychain.key(for: provider.id.uuidString) }

    @discardableResult
    static func setKey(_ key: String, for provider: ChatProvider) -> Bool {
        keychain.setKey(key, for: provider.id.uuidString)
    }

    @discardableResult
    static func remove(_ provider: ChatProvider) -> Bool { keychain.remove(provider.id.uuidString) }
}
