import Foundation
import Observation

/// Serializes read-modify-write operations and publishes state only after durable storage succeeds.
/// An unreadable repository stays read-only so a new session cannot overwrite damaged user data.
@MainActor @Observable
public final class WatchProgressController {
    public private(set) var state = WatchProgress()
    public var error: String?
    @ObservationIgnored private let writer: WatchProgressWriter
    @ObservationIgnored private var pendingSave: (id: UUID, task: Task<Bool, Never>)?
    @ObservationIgnored private var writable = true

    public init(repository: WatchProgressRepository) {
        writer = WatchProgressWriter(repository: repository)
        do {
            let loaded = try repository.load()
            state = loaded.state
            if loaded.recovered { error = "Watch progress was recovered from its last saved copy." }
        } catch {
            writable = false
            self.error = error.localizedDescription
        }
    }

    @discardableResult public func setWatched(
        _ watched: Bool, for item: MediaItem, episode: Episode? = nil
    ) -> Task<Bool, Never> {
        commit { proposed in
            proposed.setWatched(watched, for: item, episode: episode)
            return true
        }
    }

    #if !VESPER_GO
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
    #endif

    public func flush() async {
        while let pendingSave { _ = await pendingSave.task.value }
    }

    public func mergeTrakt(
        _ entries: [TraktWatchedEntry], pending: [TraktHistoryChange],
        shouldApply: @escaping @MainActor () -> Bool = { true }
    ) async -> Bool {
        await commit { proposed in
            guard shouldApply() else { return false }
            proposed.mergeTrakt(entries, pending: pending)
            return true
        }.value
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

    public func detachTrakt() async {
        _ = await commit { proposed in
            proposed.detachTrakt()
            return true
        }.value
    }

    @discardableResult private func commit(_ change: @escaping @MainActor (inout WatchProgress) -> Bool)
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
            var success = false
            var proposed = self.state
            if change(&proposed) {
                do {
                    try await self.writer.save(proposed)
                    self.state = proposed
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
