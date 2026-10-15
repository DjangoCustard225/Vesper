import Foundation

public struct LibraryState: Codable, Sendable {
    public var items: [MediaItem]
    // Codable ignores the removed history field in older libraries and backups.
    public init(items: [MediaItem] = []) { self.items = items }
}

public enum LibraryError: Error, LocalizedError, Equatable {
    case invalidBackup, unsupportedVersion, unreadable, writeFailed, tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidBackup: "This isn’t a valid Vesper library backup."
        case .unsupportedVersion:
            "This library was created by a newer version of Vesper. Its files have been preserved."
        case .unreadable: "Your library and recovery copy couldn’t be read. Their files have been preserved."
        case .writeFailed: "Couldn’t save your library. Your previous collection has been kept."
        case .tooLarge: "This library backup is too large."
        }
    }
}

public struct LibraryRepository: Sendable {
    private struct Envelope: Codable {
        let format: String
        let version: Int
        let library: LibraryState
    }
    private struct Header: Decodable {
        let format: String
        let version: Int
    }
    public let url: URL

    public var backupURL: URL { url.appendingPathExtension("backup") }
    private let write: @Sendable (Data, URL) throws -> Void

    public init(url: URL) {
        self.init(url: url, write: { try PersistenceIO.write($0, $1) })
    }

    public init(url: URL, write: @escaping @Sendable (Data, URL) throws -> Void) {
        self.url = url
        self.write = write
    }

    private func read(_ url: URL) throws -> Data {
        do { return try PersistenceIO.read(url, maximumBytes: 8 * 1024 * 1024) } catch PersistenceIO.ReadError
            .tooLarge
        { throw LibraryError.tooLarge }
    }

    public static func decode(_ data: Data) throws -> LibraryState {
        guard data.count <= 8 * 1024 * 1024 else { throw LibraryError.tooLarge }
        let decoder = JSONDecoder()
        let state: LibraryState
        if let header = try? decoder.decode(Header.self, from: data) {
            guard header.format == "vesper.library" else { throw LibraryError.invalidBackup }
            guard (1...2).contains(header.version) else { throw LibraryError.unsupportedVersion }
        }
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            guard envelope.format == "vesper.library" else { throw LibraryError.invalidBackup }
            guard (1...2).contains(envelope.version) else { throw LibraryError.unsupportedVersion }
            state = envelope.library
        } else if let legacy = try? decoder.decode(LibraryState.self, from: data) {
            state = legacy
        } else {
            throw LibraryError.invalidBackup
        }
        guard state.items.count <= 10_000,
            state.items.allSatisfy({ !$0.id.isEmpty && !$0.type.isEmpty && !$0.name.isEmpty })
        else {
            throw LibraryError.invalidBackup
        }
        return state
    }

    public static func encode(_ state: LibraryState) throws -> Data {
        try prepared(state).data
    }

    private static func prepared(_ state: LibraryState) throws -> (state: LibraryState, data: Data) {
        var compact = state
        compact.items = MediaIdentity.unique(state.items).map { item in
            var item = item
            item.videos = nil
            return item
        }
        let data = try JSONEncoder().encode(Envelope(format: "vesper.library", version: 2, library: compact))
        return (try decode(data), data)
    }

    public func load() throws -> (state: LibraryState, recovered: Bool) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            if manager.fileExists(atPath: backupURL.path) {
                guard let data = try? read(backupURL), let state = try? Self.decode(data) else {
                    throw LibraryError.unreadable
                }
                return (state, true)
            }
            return (LibraryState(), false)
        }
        do { return (try Self.decode(read(url)), false) } catch LibraryError.unsupportedVersion {
            throw LibraryError.unsupportedVersion
        } catch {
            guard let data = try? read(backupURL), let state = try? Self.decode(data) else {
                throw LibraryError.unreadable
            }
            return (state, true)
        }
    }

    public func save(_ state: LibraryState) throws {
        try savePrepared(Self.prepared(state).data)
    }

    private func savePrepared(_ data: Data) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                // Failure to read the current file is not permission to overwrite it.
                do {
                    let old = try read(url)
                    do {
                        _ = try Self.decode(old)
                        try write(old, backupURL)
                    } catch LibraryError
                        .unsupportedVersion
                    { throw LibraryError.unsupportedVersion } catch LibraryError.invalidBackup {
                        let preserved = url.deletingLastPathComponent().appendingPathComponent(
                            "library-corrupt-\(UUID().uuidString).json")
                        try write(old, preserved)
                    }
                } catch LibraryError.tooLarge {
                    let preserved = url.deletingLastPathComponent().appendingPathComponent(
                        "library-corrupt-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: url, to: preserved)
                }
            }
            try write(data, url)
        } catch let error as LibraryError { throw error } catch { throw LibraryError.writeFailed }
    }

    public func commit(_ proposed: LibraryState, current: inout LibraryState) throws {
        let prepared = try Self.prepared(proposed)
        try savePrepared(prepared.data)
        current = prepared.state
    }

    public static func merging(_ imported: LibraryState, into current: LibraryState) -> LibraryState {
        LibraryState(items: MediaIdentity.unique(current.items + imported.items))
    }
}
