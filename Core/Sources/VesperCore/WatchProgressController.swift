import Foundation
import Observation

/// Serializes read-modify-write operations and publishes state only after durable storage succeeds.
/// An unreadable repository stays read-only so a new session cannot overwrite damaged user data.
@MainActor @Observable
public final class WatchProgressController {
    public private(set) var state = WatchProgress()
    private var statusIndex = WatchStatusIndex()
    public var error: String?
    /// Increments on every committed change, so a sync can tell whether state moved underneath it.
    @ObservationIgnored public private(set) var revision = 0
    @ObservationIgnored private let writer: WatchProgressWriter
    @ObservationIgnored private var pendingSave: (id: UUID, task: Task<Bool, Never>)?
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var loading: Task<Bool, Never>?

    /// With `loadInBackground`, the file is read and decoded off the main actor so launch isn't held
    /// up. Until it finishes, `state` is empty; changes queue behind the load, and
    /// `waitUntilLoaded()` or `flush()` wait for it.
    public init(repository: WatchProgressRepository, loadInBackground: Bool = false) {
        writer = WatchProgressWriter(repository: repository)
        guard loadInBackground else {
            apply(Result { try Self.load(repository) })
            return
        }
        let id = UUID()
        let task = Task<Bool, Never> {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.load(repository) }
            }.value
            self.apply(result)
            if self.pendingSave?.id == id { self.pendingSave = nil }
            return true
        }
        pendingSave = (id, task)
        loading = task
    }

    private nonisolated static func load(_ repository: WatchProgressRepository) throws -> (
        state: WatchProgress, index: WatchStatusIndex, recovered: Bool
    ) {
        let loaded = try repository.load()
        return (loaded.state, WatchStatusIndex(loaded.state), loaded.recovered)
    }

    private func apply(
        _ result: Result<(state: WatchProgress, index: WatchStatusIndex, recovered: Bool), Error>
    ) {
        switch result {
        case .success(let loaded):
            state = loaded.state
            statusIndex = loaded.index
            if loaded.recovered { error = "Watch progress was recovered from its last saved copy." }
        case .failure(let failure):
            writable = false
            error = failure.localizedDescription
        }
    }

    /// Returns once saved progress has been read.
    public func waitUntilLoaded() async { _ = await loading?.value }

    public func isWatched(_ media: MediaItem, episode: Episode? = nil) -> Bool {
        statusIndex.isWatched(media, episode: episode)
    }

    @discardableResult public func setWatched(
        _ watched: Bool, for item: MediaItem, episode: Episode? = nil
    ) -> Task<Bool, Never> {
        commit { proposed in
            proposed.setWatched(watched, for: item, episode: episode)
            return true
        }
    }

    @discardableResult public func removeFromContinueWatching(for item: MediaItem) -> Task<Bool, Never> {
        commit { proposed in
            proposed.removeFromContinueWatching(for: item)
            return true
        }
    }

    public func record(media: MediaItem, videoID: String, subtitle: String?, update: PlaybackProgressUpdate) {
        commit { proposed in
            proposed.record(
                media: media, videoID: videoID, subtitle: subtitle,
                elapsed: update.elapsed, duration: update.duration, ended: update.ended)
        }
    }

    /// Replaces all progress with a synced result, unless a local change committed since `revision`.
    public func applySynced(_ progress: WatchProgress, ifRevision revision: Int) async -> Bool {
        await commit { proposed in
            guard self.revision == revision else { return false }
            proposed = progress
            return true
        }.value
    }

    public func flush() async {
        while let pendingSave { _ = await pendingSave.task.value }
    }

    public func mergeTrakt(
        _ entries: [TraktWatchedEntry], pending: [TraktHistoryChange],
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        await importHistory(shouldApply: shouldApply) {
            $0.mergeTrakt(entries, pending: pending)
        }
    }

    public func replaceTraktHistory(
        for media: MediaItem, with entries: [TraktWatchedEntry], pending: [TraktHistoryChange],
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        await commit { proposed in
            guard shouldApply() else { return false }
            proposed.replaceTraktHistory(for: media, with: entries, pending: pending)
            return true
        }.value
    }

    public func mergeSimkl(
        _ entries: [TraktWatchedEntry], pending: [TraktHistoryChange],
        shouldApply: @escaping @MainActor () -> Bool
    ) async -> Bool {
        await importHistory(shouldApply: shouldApply) {
            $0.mergeSimkl(entries, pending: pending)
        }
    }

    public func detachTrakt() async {
        _ = await commit { proposed in
            proposed.detachTrakt()
            return true
        }.value
    }

    /// Runs bulk imports off the UI actor while retaining the same durable mutation queue.
    private func importHistory(
        shouldApply: @escaping @MainActor () -> Bool,
        change: @escaping @Sendable (inout WatchProgress) -> Void
    ) async -> Bool {
        await commitPrepared {
            guard shouldApply() else { return nil }
            let current = self.state
            let proposed = await Task.detached(priority: .utility) {
                var value = current
                change(&value)
                return value
            }.value
            return shouldApply() ? proposed : nil
        }.value
    }

    @discardableResult private func commit(_ change: @escaping @MainActor (inout WatchProgress) -> Bool)
        -> Task<Bool, Never>
    {
        commitPrepared {
            var proposed = self.state
            return change(&proposed) ? proposed : nil
        }
    }

    private func commitPrepared(_ prepare: @escaping @MainActor () async -> WatchProgress?)
        -> Task<Bool, Never>
    {
        guard writable else {
            error = WatchProgressError.unreadable.localizedDescription
            return Task { false }
        }
        let previous = pendingSave?.task
        let id = UUID()
        let task = Task<Bool, Never> {
            // Each change starts from the preceding successful commit, not a stale UI snapshot.
            _ = await previous?.value
            // A change queued while loading must not overwrite a file that turned out unreadable.
            guard self.writable else {
                self.error = WatchProgressError.unreadable.localizedDescription
                if self.pendingSave?.id == id { self.pendingSave = nil }
                return false
            }
            var success = false
            if let proposed = await prepare() {
                do {
                    try await self.writer.save(proposed)
                    let committed = proposed
                    let index = await Task.detached(priority: .utility) {
                        WatchStatusIndex(committed)
                    }.value
                    self.state = proposed
                    self.statusIndex = index
                    self.revision += 1
                    success = true
                } catch { self.error = error.localizedDescription }
            }
            if self.pendingSave?.id == id { self.pendingSave = nil }
            return success
        }
        pendingSave = (id, task)
        return task
    }
}
