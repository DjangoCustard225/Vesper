import Foundation

public struct TraktSyncState: Codable, Sendable {
    public var account: TraktAccount?
    public var pending: [TraktHistoryChange] = []
    public var fingerprint: String?
    public var lastSyncedAt: Date?

    public init() {}

    public mutating func enqueue(_ change: TraktHistoryChange) throws {
        guard WatchProgress.supports(change.media), TraktIDs(change.media).lookup != nil else {
            throw TraktError.unidentifiedTitle
        }
        guard !pending.contains(where: { $0.id == change.id }) else { return }
        if change.action != .stopped {
            coalesce(change)
        }
        guard pending.count < 500 else { throw TraktStateError.queueFull }
        pending.append(change)
    }

    private mutating func coalesce(_ change: TraktHistoryChange) {
        pending.removeAll { previous in
            guard previous.action != .stopped else { return false }
            guard previous.media.isSameTitle(as: change.media) else { return false }
            guard change.media.type == "series", let videoID = change.videoID else { return true }
            guard let previousID = previous.videoID else { return false }
            if let episode = TraktClient.episode(videoID), let other = TraktClient.episode(previousID) {
                return episode.season == other.season && episode.number == other.number
            }
            return videoID == previousID
        }
    }
}

public enum TraktStateError: Error, LocalizedError {
    case unreadable, queueFull

    public var errorDescription: String? {
        switch self {
        case .unreadable: "Saved Trakt sync data couldn’t be read. It has been preserved."
        case .queueFull: "Trakt has too many unsent changes. Sync your account before adding more."
        }
    }
}

/// Stores only account identity, sync timestamps, and unsent edits. OAuth tokens live in Keychain.
public struct TraktStateRepository: Sendable {
    private struct Envelope: Codable { let version: Int; let state: TraktSyncState }
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> TraktSyncState {
        let manager = FileManager.default
        let backup = url.appendingPathExtension("backup")
        guard manager.fileExists(atPath: url.path) || manager.fileExists(atPath: backup.path) else {
            return TraktSyncState()
        }
        for candidate in [url, backup] {
            if let data = try? PersistenceIO.read(candidate, maximumBytes: 2 * 1024 * 1024),
                let value = try? decode(data)
            {
                return value
            }
        }
        throw TraktStateError.unreadable
    }

    public func save(_ state: TraktSyncState) throws {
        let data = try JSONEncoder().encode(Envelope(version: 1, state: state))
        _ = try decode(data)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let previous = try? PersistenceIO.read(url, maximumBytes: 2 * 1024 * 1024),
            (try? decode(previous)) != nil
        {
            let backup = url.appendingPathExtension("backup")
            try PersistenceIO.write(previous, backup)
            try PersistenceIO.excludeFromBackup(backup)
        }
        try PersistenceIO.write(data, url)
        try PersistenceIO.excludeFromBackup(url)
    }

    public func reset() throws {
        for candidate in [url, url.appendingPathExtension("backup")] {
            if FileManager.default.fileExists(atPath: candidate.path) {
                // Disconnect may explicitly reset damaged state, while retaining the original for recovery.
                try FileManager.default.moveItem(
                    at: candidate, to: candidate.appendingPathExtension("disconnected-" + UUID().uuidString))
            }
        }
        try save(TraktSyncState())
    }

    private func decode(_ data: Data) throws -> TraktSyncState {
        guard data.count <= 2 * 1024 * 1024,
            let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
            value.state.pending.count <= 500,
            value.state.pending.allSatisfy({
                guard WatchProgress.supports($0.media), !$0.media.id.isEmpty, $0.media.videos == nil else {
                    return false
                }
                return $0.progress.map { $0.isFinite && (0...100).contains($0) } ?? true
            })
        else { throw TraktStateError.unreadable }
        return value.state
    }
}
