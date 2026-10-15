import Foundation
import Observation

/// Serializes read-modify-write operations and publishes state only after durable storage succeeds.
/// An unreadable repository stays read-only so a new session cannot overwrite damaged user data.
@MainActor @Observable
public final class WatchProgressController {
    public private(set) var state = WatchProgress()
    public var error: String?
    @ObservationIgnored private let writer: WatchProgressWriter
    @ObservationIgnored private var pendingSave: (id: UUID, task: Task<Void, Never>)?
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

    public func setWatched(_ watched: Bool, for item: MediaItem) {
        commit { proposed in
            proposed.setWatched(watched, for: item)
            return true
        }
    }

    #if !VESPER_GO
    public func record(media: MediaItem, videoID: String, subtitle: String?, update: PlaybackProgressUpdate) {
        commit { proposed in
            proposed.record(
                media: media, videoID: videoID, subtitle: subtitle,
                elapsed: update.elapsed, duration: update.duration, ended: update.ended)
        }
    }
    #endif

    public func flush() async {
        while let pendingSave { await pendingSave.task.value }
    }

    private func commit(_ change: @escaping @MainActor (inout WatchProgress) -> Bool) {
        guard writable else {
            error = WatchProgressError.unreadable.localizedDescription
            return
        }
        let previous = pendingSave?.task
        let id = UUID()
        let task = Task {
            // Each change starts from the preceding successful commit, not a stale UI snapshot.
            await previous?.value
            var proposed = self.state
            if change(&proposed) {
                do {
                    try await self.writer.save(proposed)
                    self.state = proposed
                } catch { self.error = error.localizedDescription }
            }
            if self.pendingSave?.id == id { self.pendingSave = nil }
        }
        pendingSave = (id, task)
    }
}
