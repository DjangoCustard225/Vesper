import Foundation

public struct CachedValue<Value: Sendable>: Sendable {
    public let value: Value
    public let savedAt: Date
    public let isFresh: Bool
}

/// Re-creatable metadata only. Never store credentials or playback responses here.
public actor ResponseCache {
    private struct Entry: Codable {
        let version: Int
        let key: String
        let savedAt: Date
        let data: Data
    }
    private let directory: URL
    private let limit: Int
    private var generation = UUID()
    private var refreshes: [String: Task<Void, Never>] = [:]
    private struct FileEntry {
        let size: Int
        let modified: Date
    }
    private var index: [URL: FileEntry]?
    private var byteCount = 0

    public init(directory: URL, byteLimit: Int = 32 * 1024 * 1024) {
        self.directory = directory
        limit = byteLimit
    }

    public func token() -> UUID { generation }

    public func value<T: Codable & Sendable>(
        _ type: T.Type, key: String, ttl: TimeInterval, now: Date = Date()
    ) -> CachedValue<T>? {
        let url = file(key)
        guard let bytes = try? PersistenceIO.read(url, maximumBytes: 12_000_000),
            let entry = try? JSONDecoder().decode(Entry.self, from: bytes), entry.version == 1,
            entry.key == Self.fingerprint(key), now.timeIntervalSince(entry.savedAt) >= -60,
            now.timeIntervalSince(entry.savedAt) < 7 * 24 * 3600,
            let value = try? JSONDecoder().decode(type, from: entry.data)
        else {
            remove(url)
            return nil
        }
        return CachedValue(
            value: value, savedAt: entry.savedAt, isFresh: now.timeIntervalSince(entry.savedAt) < ttl)
    }

    public func save<T: Codable & Sendable>(_ value: T, key: String, token: UUID? = nil, now: Date = Date()) {
        guard token == nil || token == generation, let payload = try? JSONEncoder().encode(value),
            payload.count < 8_000_000,
            let data = try? JSONEncoder().encode(
                Entry(version: 1, key: Self.fingerprint(key), savedAt: now, data: payload)),
            data.count <= limit
        else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            initializeIndex()
            try PersistenceIO.write(data, file(key))
            let url = file(key)
            byteCount += data.count - (index?[url]?.size ?? 0)
            index?[url] = FileEntry(size: data.count, modified: Date())
            prune()
        } catch { /* A cache failure must not prevent browsing. */  }
    }

    public func clear() {
        try? removeAll()
    }

    public func removeAll() throws {
        generation = UUID()
        for task in refreshes.values { task.cancel() }
        refreshes = [:]
        index = nil
        byteCount = 0
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func refresh(key: String, operation: @escaping @Sendable () async throws -> Void) {
        guard refreshes[key] == nil else { return }
        let token = generation
        refreshes[key] = Task {
            do {
                try await operation()
                try Task.checkCancellation()
                if token == generation {
                    NotificationCenter.default.post(
                        name: .vesperMetadataUpdated, object: MetadataUpdate(key: key))
                }
            } catch {}
            if token == generation { refreshes[key] = nil }
        }
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(Self.fingerprint(key) + ".json")
    }

    private func initializeIndex() {
        guard index == nil else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files =
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys))
            ?? []
        index = [:]
        byteCount = 0
        for url in files where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let size = values.fileSize ?? 0
            index?[url] = FileEntry(size: size, modified: values.contentModificationDate ?? .distantPast)
            byteCount += size
        }
    }

    private func remove(_ url: URL) {
        let removed = (try? FileManager.default.removeItem(at: url)) != nil
        if removed || !FileManager.default.fileExists(atPath: url.path) {
            if let entry = index?.removeValue(forKey: url) { byteCount -= entry.size }
        }
    }

    private func prune() {
        guard byteCount > limit || (index?.count ?? 0) > 250 else { return }
        for (url, _) in (index ?? [:]).sorted(by: { $0.value.modified < $1.value.modified }) {
            guard byteCount > limit || (index?.count ?? 0) > 250 else { break }
            remove(url)
        }
    }
    // Stable opaque filenames; the original key (which may include provider configuration)
    // never goes on disk. This is a cache identifier, not a cryptographic primitive.
    public nonisolated static func fingerprint(_ value: String) -> String {
        var first: UInt64 = 14695981039346656037, second: UInt64 = 7809847782465536322
        for byte in value.utf8 {
            first = (first ^ UInt64(byte)) &* 1099511628211

            second = (second ^ UInt64(byte)) &* 14029467366897019727
        }
        return String(format: "%016llx%016llx", first, second)
    }
}

public extension Notification.Name {
    static let vesperMetadataUpdated = Notification.Name("app.vesper.metadataUpdated")
}
