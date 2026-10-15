import Foundation

public struct PlaybackProgressUpdate: Equatable, Sendable {
    public let elapsed: Double
    public let duration: Double
    public let ended: Bool

    public init(elapsed: Double, duration: Double, ended: Bool) {
        self.elapsed = elapsed
        self.duration = duration
        self.ended = ended
    }

    public var isComplete: Bool { ended || (duration > 0 && elapsed / duration >= 0.95) }
}

/// Throttles periodic checkpoints while saving completion transitions and explicit checkpoints immediately.
/// The engine remains responsible for suppressing updates during loading, seeks, and live playback.
public struct PlaybackProgressReporter: Sendable {
    private var lastUpdate: PlaybackProgressUpdate?
    private var lastReportedAt: TimeInterval = -.infinity

    public init() {}

    public mutating func checkpoint(
        timeline: PlaybackTimeline, ended: Bool, force: Bool, now: TimeInterval
    ) -> PlaybackProgressUpdate? {
        guard timeline.isSeekable, timeline.duration > 0, timeline.elapsed >= 5 || ended else { return nil }
        let update = PlaybackProgressUpdate(
            elapsed: timeline.elapsed, duration: timeline.duration, ended: ended)
        let completionChanged = update.isComplete != (lastUpdate?.isComplete ?? false)
        guard update != lastUpdate, force || completionChanged || now - lastReportedAt >= 15 else {
            return nil
        }
        lastUpdate = update
        lastReportedAt = now
        return update
    }
}
