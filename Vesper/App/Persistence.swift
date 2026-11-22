import Foundation
import Security
import VesperCore
import UsenetEngine

enum SecureStorage {
    struct Key<Value: Codable>: Sendable {
        fileprivate let account: String
    }

    // Namespace credentials for Vesper's application identity.
    private static let service = AppIdentity.bundleID

    static func load<Value>(_ key: Key<Value>) throws -> Value? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key.account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.keychainRead }
        guard let data = result as? Data, let value = try? JSONDecoder().decode(Value.self, from: data) else {
            throw StorageError.unreadable
        }
        return value
    }

    /// Everything Vesper keeps in the Keychain, read with one query. Launch reads several values,
    /// and one query is cheaper than one each.
    struct Snapshot {
        /// nil when the combined read failed; values are then read one at a time.
        fileprivate let items: [String: Data]?

        func load<Value>(_ key: Key<Value>) throws -> Value? {
            guard let items else { return try SecureStorage.load(key) }
            guard let data = items[key.account] else { return nil }
            guard let value = try? JSONDecoder().decode(Value.self, from: data) else {
                throw StorageError.unreadable
            }
            return value
        }

        /// Unknown after a failed read counts as present, so cleanup still runs.
        func contains<Value>(_ key: Key<Value>) -> Bool { items.map { $0[key.account] != nil } ?? true }
    }

    static func snapshot() -> Snapshot {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return Snapshot(items: [:]) }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else {
            return Snapshot(items: nil)
        }
        var items: [String: Data] = [:]
        for row in rows {
            if let account = row[kSecAttrAccount as String] as? String,
                let data = row[kSecValueData as String] as? Data
            {
                items[account] = data
            }
        }
        return Snapshot(items: items)
    }

    static func save<Value>(_ value: Value, for key: Key<Value>) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key.account,
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError.keychain }
    }

    static func delete<Value>(_ key: Key<Value>) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain }
    }
}

extension SecureStorage.Key where Value == [InstalledAddon] {
    static var addons: Self { Self(account: "addons") }
}

extension SecureStorage.Key where Value == String {
    static var nzbfinderAPIKey: Self { Self(account: "nzbfinderAPIKey") }

    static var tmdbCredential: Self { Self(account: "tmdbCredential") }
    static var mdblistKey: Self { Self(account: "mdblistKey") }

    static var heroCatalog: Self { Self(account: "heroCatalog") }
    static var retiredFanartCredentials: Self { Self(account: "fanartCredentials") }
}

extension SecureStorage.Key where Value == CatalogPreferences {
    static var catalogPreferences: Self { Self(account: "catalogPreferences") }
}

extension SecureStorage.Key where Value == TVDBCredentials {
    static var tvdbCredentials: Self { Self(account: "tvdbCredentials") }
}
extension SecureStorage.Key where Value == TraktTokens {
    static var traktTokens: Self { Self(account: "traktTokens") }
}

enum StorageError: LocalizedError {
    case keychain, keychainRead, unreadable

    var errorDescription: String? {
        switch self {
        case .keychain: "Couldn’t save securely. Unlock your device and try again."
        case .keychainRead:
            "Couldn’t read saved settings securely. They have been preserved. Unlock your device and try again."
        case .unreadable: "Saved settings couldn’t be read. Their original data has been preserved."
        }
    }
}

enum LibraryStorage {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vesper/library.json")
    }

    static var repository: LibraryRepository { LibraryRepository(url: url) }

    static func load() throws -> (state: LibraryState, recovered: Bool) {
        if FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: repository.backupURL.path)
        {
            return try repository.load()
        }
        let legacy = url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftStream/library.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return (LibraryState(), false) }
        let state = try LibraryRepository.decode(Data(contentsOf: legacy))
        try repository.save(state)
        return (state, false)
    }
}

enum WatchProgressStorage {
    static var repository: WatchProgressRepository {
        WatchProgressRepository(
            url: LibraryStorage.url.deletingLastPathComponent().appendingPathComponent("watch-progress.json"))
    }
}

extension SecureStorage.Key where Value == UsenetProvider {
    static var usenetProvider: Self { Self(account: "usenetProvider") }
}

extension SecureStorage.Key where Value == String {
    static func archivePassword(_ id: UUID) -> Self {
        Self(account: "usenetArchivePassword:" + id.uuidString)
    }
}
extension SecureStorage.Key where Value == [UsenetProvider] {
    static var usenetBackupProviders: Self { Self(account: "usenetBackupProviders") }
}

extension SecureStorage.Key where Value == SimklTokens {
    static var simklTokens: Self { Self(account: "simklTokens") }
}

extension SecureStorage.Key where Value == String {
    static var subdlAPIKey: Self { Self(account: "subdlAPIKey") }
}
