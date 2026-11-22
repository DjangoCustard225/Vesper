import Foundation

/// One device's view of everything Vesper syncs. Each device writes its own snapshot file, so two
/// devices never edit the same file; every device merges all snapshots it can read.
///
/// Conflicts resolve per item, last change wins: a library title, a title's watch progress, and each
/// settings blob carry their own `changedAt`. Removals are kept as tombstones so they propagate.
public struct SyncSnapshot: Codable, Sendable {
    public static let format = "vesper-sync"
    public static let currentVersion = 1

    public var format = SyncSnapshot.format
    public var version = SyncSnapshot.currentVersion
    public var deviceID: String
    public var deviceName: String
    public var savedAt: Date
    public var library: [SyncLibraryEntry]
    public var progress: [SyncProgressTitle]
    public var blobs: [String: SyncBlob]

    public init(
        deviceID: String, deviceName: String, savedAt: Date, library: [SyncLibraryEntry] = [],
        progress: [SyncProgressTitle] = [], blobs: [String: SyncBlob] = [:]
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.savedAt = savedAt
        self.library = library
        self.progress = progress
        self.blobs = blobs
    }

    /// Library titles in display order: most recently added first.
    public var libraryState: LibraryState {
        let present = library.enumerated().filter { !$0.element.removed }
            .sorted { ($0.element.changedAt, -$0.offset) > ($1.element.changedAt, -$1.offset) }
        return LibraryState(items: MediaIdentity.unique(present.map(\.element.item)))
    }

    public var watchProgress: WatchProgress {
        WatchProgress(syncedRecords: progress.flatMap(\.records))
    }

    public static let maximumFileBytes = 32 * 1024 * 1024

    /// Reads a sync or sync-state file with a size limit.
    public static func readFile(_ url: URL) throws -> Data {
        try PersistenceIO.read(url, maximumBytes: maximumFileBytes)
    }

    /// Writes this device's private sync state atomically.
    public static func writeStateFile(_ data: Data, to url: URL) throws {
        try PersistenceIO.write(data, url)
    }

    public static func decode(_ data: Data) throws -> SyncSnapshot {
        let snapshot = try JSONDecoder().decode(SyncSnapshot.self, from: data)
        guard snapshot.format == format else { throw SyncError.invalidFile }
        guard snapshot.version <= currentVersion else { throw SyncError.newerVersion }
        return snapshot
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public struct SyncLibraryEntry: Codable, Sendable {
    public var item: MediaItem
    public var removed: Bool
    public var changedAt: Date

    public init(item: MediaItem, removed: Bool = false, changedAt: Date) {
        self.item = item
        self.removed = removed
        self.changedAt = changedAt
    }
}

/// All watch records for one title. No records means the title's history was cleared.
public struct SyncProgressTitle: Codable, Sendable {
    public var media: MediaItem
    public var records: [WatchRecord]
    public var changedAt: Date

    public init(media: MediaItem, records: [WatchRecord], changedAt: Date) {
        self.media = media
        self.records = records
        self.changedAt = changedAt
    }
}

/// An opaque settings payload, replaced as a whole by the newest change.
public struct SyncBlob: Codable, Sendable, Equatable {
    public var payload: Data
    public var changedAt: Date

    public init(payload: Data, changedAt: Date) {
        self.payload = payload
        self.changedAt = changedAt
    }
}

public enum SyncError: Error, LocalizedError, Equatable {
    case invalidFile, newerVersion

    public var errorDescription: String? {
        switch self {
        case .invalidFile: "A sync file in the folder isn’t a Vesper sync file."
        case .newerVersion: "Another device uses a newer version of Vesper. Update Vesper to sync with it."
        }
    }
}

public enum SyncEngine {
    /// Tombstones older than this are dropped; a device offline for longer may restore removed items.
    public static let tombstoneLifetime: TimeInterval = 180 * 24 * 3600

    /// Describes this device's current state, dating each change against the previous snapshot.
    /// With no previous snapshot (first sync), library titles and settings date from the distant
    /// past so they merge with other devices instead of overriding them.
    public static func localSnapshot(
        previous: SyncSnapshot?, library: LibraryState, progress: WatchProgress, blobs: [String: Data],
        deviceID: String, deviceName: String, now: Date = Date()
    ) -> SyncSnapshot {
        let firstSync = previous == nil
        let fresh = firstSync ? Date.distantPast : now

        // Library
        let previousLibrary = previous?.library ?? []
        let previousAliases = previousLibrary.map { MediaIdentity.aliases($0.item) }
        var matchedPrevious = Set<Int>()
        var entries: [SyncLibraryEntry] = []
        for item in library.items {
            let aliases = MediaIdentity.aliases(item)
            let match = previousAliases.indices.first {
                !matchedPrevious.contains($0) && !previousAliases[$0].isDisjoint(with: aliases)
            }
            if let match { matchedPrevious.insert(match) }
            let changedAt =
                match.flatMap { previousLibrary[$0].removed ? nil : previousLibrary[$0].changedAt } ?? fresh
            entries.append(SyncLibraryEntry(item: item, changedAt: changedAt))
        }
        for (index, entry) in previousLibrary.enumerated() where !matchedPrevious.contains(index) {
            if entry.removed {
                if now.timeIntervalSince(entry.changedAt) < tombstoneLifetime { entries.append(entry) }
            } else {
                entries.append(SyncLibraryEntry(item: entry.item, removed: true, changedAt: now))
            }
        }

        // Watch progress
        let previousTitles = previous?.progress ?? []
        let previousTitleAliases = previousTitles.map { MediaIdentity.aliases($0.media) }
        var matchedTitles = Set<Int>()
        var titles: [SyncProgressTitle] = []
        for group in groupRecords(progress.records) {
            let media = group[0].media
            let aliases = group.reduce(into: Set<String>()) { $0.formUnion(MediaIdentity.aliases($1.media)) }
            let match = previousTitleAliases.indices.first {
                !matchedTitles.contains($0) && !previousTitleAliases[$0].isDisjoint(with: aliases)
            }
            if let match { matchedTitles.insert(match) }
            let latest = group.map(\.updatedAt).max() ?? now
            let changedAt: Date
            if let match, fingerprint(previousTitles[match].records) == fingerprint(group) {
                changedAt = previousTitles[match].changedAt
            } else {
                changedAt = firstSync ? latest : max(now, latest)
            }
            titles.append(SyncProgressTitle(media: media, records: group, changedAt: changedAt))
        }
        for (index, title) in previousTitles.enumerated() where !matchedTitles.contains(index) {
            if title.records.isEmpty {
                if now.timeIntervalSince(title.changedAt) < tombstoneLifetime { titles.append(title) }
            } else {
                titles.append(SyncProgressTitle(media: title.media, records: [], changedAt: now))
            }
        }

        // Settings
        var syncedBlobs: [String: SyncBlob] = [:]
        for (key, payload) in blobs {
            if let old = previous?.blobs[key], old.payload == payload {
                syncedBlobs[key] = old
            } else {
                syncedBlobs[key] = SyncBlob(payload: payload, changedAt: fresh)
            }
        }

        return SyncSnapshot(
            deviceID: deviceID, deviceName: deviceName, savedAt: now, library: entries, progress: titles,
            blobs: syncedBlobs)
    }

    /// Merges snapshots. On equal timestamps the local snapshot wins, then the lower device ID.
    public static func merge(local: SyncSnapshot, remotes: [SyncSnapshot], now: Date = Date()) -> SyncSnapshot
    {
        let ordered =
            [local] + remotes.filter { $0.deviceID != local.deviceID }.sorted { $0.deviceID < $1.deviceID }

        // Library: newest entry per title.
        let libraryEntries = ordered.flatMap(\.library)
        var library: [SyncLibraryEntry] = []
        for group in groups(libraryEntries.map { MediaIdentity.aliases($0.item) }) {
            let winner = group.dropFirst().reduce(group[0]) { best, index in
                libraryEntries[index].changedAt > libraryEntries[best].changedAt ? index : best
            }
            let entry = libraryEntries[winner]
            if !entry.removed || now.timeIntervalSince(entry.changedAt) < tombstoneLifetime {
                library.append(entry)
            }
        }

        // Progress: newest title wins as a whole, keeping a title's records consistent.
        let titleEntries = ordered.flatMap(\.progress)
        var progress: [SyncProgressTitle] = []
        for group in groups(
            titleEntries.map { title in
                title.records.reduce(into: MediaIdentity.aliases(title.media)) {
                    $0.formUnion(MediaIdentity.aliases($1.media))
                }
            })
        {
            let winner = group.dropFirst().reduce(group[0]) { best, index in
                titleEntries[index].changedAt > titleEntries[best].changedAt ? index : best
            }
            let title = titleEntries[winner]
            if !title.records.isEmpty || now.timeIntervalSince(title.changedAt) < tombstoneLifetime {
                progress.append(title)
            }
        }

        // Settings: newest blob per key.
        var blobs: [String: SyncBlob] = [:]
        for snapshot in ordered {
            for (key, blob) in snapshot.blobs where blobs[key].map({ blob.changedAt > $0.changedAt }) ?? true
            {
                blobs[key] = blob
            }
        }

        return SyncSnapshot(
            deviceID: local.deviceID, deviceName: local.deviceName, savedAt: now, library: library,
            progress: progress, blobs: blobs)
    }

    /// Splits records into titles, joining records whose identities overlap.
    static func groupRecords(_ records: [WatchRecord]) -> [[WatchRecord]] {
        groups(records.map { MediaIdentity.aliases($0.media) }).map { $0.map { records[$0] } }
    }

    /// Groups indices whose alias sets overlap, directly or through other members.
    /// Groups keep first-appearance order and members keep input order.
    static func groups(_ aliases: [Set<String>]) -> [[Int]] {
        var parents = Array(aliases.indices), owners: [String: Int] = [:]
        func root(_ index: Int) -> Int {
            var node = index
            while parents[node] != node {
                parents[node] = parents[parents[node]]
                node = parents[node]
            }
            return node
        }
        for (index, set) in aliases.enumerated() {
            for alias in set {
                if let owner = owners[alias] {
                    let a = root(owner), b = root(index)
                    if a != b { parents[max(a, b)] = min(a, b) }
                } else {
                    owners[alias] = index
                }
            }
        }
        var order: [Int] = [], members: [Int: [Int]] = [:]
        for index in aliases.indices {
            let group = root(index)
            if members[group] == nil { order.append(group) }
            members[group, default: []].append(index)
        }
        return order.map { members[$0]! }
    }

    private static func fingerprint(_ records: [WatchRecord]) -> Set<String> {
        Set(
            records.map {
                [
                    $0.id, String($0.elapsed), String($0.duration), String($0.watched),
                    String($0.updatedAt.timeIntervalSinceReferenceDate),
                    String($0.hiddenFromContinueWatching == true),
                ].joined(separator: "|")
            })
    }
}
