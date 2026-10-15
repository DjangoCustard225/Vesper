import Foundation

/// Session-only timing shared by the player controls. Nothing is persisted.
public struct PlaybackTimeline: Equatable, Sendable {
    public let elapsed: Double
    public let duration: Double
    public let isSeekable: Bool

    public init(elapsed: Double, duration: Double, isSeekable: Bool) {
        self.duration = duration.isFinite && duration > 0 ? duration : 0
        let time = elapsed.isFinite ? max(0, elapsed) : 0
        self.elapsed = self.duration > 0 ? min(time, self.duration) : time
        self.isSeekable = isSeekable && self.duration > 0
    }

    public var progress: Double { duration > 0 ? elapsed / duration : 0 }

    public var remaining: Double { max(0, duration - elapsed) }

    public func seekTarget(fraction: Double) -> Double? {
        guard isSeekable, fraction.isFinite else { return nil }
        return min(1, max(0, fraction)) * duration
    }

    public func skipTarget(seconds: Double) -> Double? {
        guard isSeekable, seconds.isFinite else { return nil }
        return min(duration, max(0, elapsed + seconds))
    }

    public static func label(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 2) else { return "0:00" }
        let value = Int(seconds)
        let tail = String(format: "%02d", value % 60)
        if value >= 3600 { return "\(value / 3600):" + String(format: "%02d", value / 60 % 60) + ":" + tail }
        return "\(value / 60):" + tail
    }
}
