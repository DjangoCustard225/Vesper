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
    case keychain, disk
    var errorDescription: String? {
        switch self {
        case .keychain: "Couldn’t save securely. Unlock your device and try again."
        case .disk: "Couldn’t save your library. Check available device storage."
        }
    }
}

struct LibraryState: Codable {
    var items: [MediaItem] = []
    var history: [WatchProgress] = []
}

enum LibraryStorage {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vesper/library.json")
    }
    static func load() throws -> LibraryState {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: url))
        }
        let legacy = url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SwiftStream/library.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return LibraryState() }
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: legacy))
        try save(state)
        return state
    }
    static func save(_ state: LibraryState) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { throw StorageError.disk }
    }
}
