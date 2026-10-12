import Foundation
import Security
import VesperCore

enum SecureStorage {
    // Namespace credentials for Vesper's application identity.
    private static let service = "app.vesper"
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StorageError.keychain }
    }
    static func delete(key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain }
    }
}

enum StorageError: LocalizedError {
    case keychain
    var errorDescription: String? { "Couldn’t save securely. Unlock your device and try again." }
}

enum LibraryStorage {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vesper/library.json")
    }
    static var repository: LibraryRepository { LibraryRepository(url: url) }
    static func load() throws -> (state: LibraryState, recovered: Bool) {
        if FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: repository.backupURL.path) {
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
        WatchProgressRepository(url: LibraryStorage.url.deletingLastPathComponent().appendingPathComponent("watch-progress.json"))
    }
}
