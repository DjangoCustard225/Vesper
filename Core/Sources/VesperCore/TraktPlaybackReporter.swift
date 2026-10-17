#if !VESPER_GO
import Foundation

public struct TraktPlaybackSample: Equatable, Sendable {
    public let elapsed: Double
    public let duration: Double
    public let playing: Bool
    public let buffering: Bool
    public let ended: Bool

    public init(elapsed: Double, duration: Double, playing: Bool, buffering: Bool, ended: Bool) {
        self.elapsed = elapsed
        self.duration = duration
        self.playing = playing
        self.buffering = buffering
        self.ended = ended
    }
}

public struct TraktScrobbleEvent: Sendable {
    public let sessionID: UUID
    public let action: TraktScrobbleAction
    public let progress: Double
}

/// Emits lifecycle transitions, not periodic network heartbeats or temporary buffering transitions.
public struct TraktPlaybackReporter: Sendable {
    private var lastAction: TraktScrobbleAction?
    private var lastProgress: Double = 0
    private var finished = false
    private var sessionID = UUID()

    public init() {}

    public mutating func update(_ sample: TraktPlaybackSample) -> TraktScrobbleEvent? {
        guard sample.duration.isFinite, sample.duration > 0, sample.elapsed.isFinite, sample.elapsed >= 0
        else {
            return nil
        }
        if finished {
            // A deliberate replay starts a fresh watching cycle after completion.
            guard sample.playing, !sample.ended, sample.elapsed / sample.duration < 0.8 else { return nil }
            finished = false
            lastAction = nil
            sessionID = UUID()
        }
        lastProgress = min(100, max(0, sample.elapsed / sample.duration * 100))
        if sample.ended { lastProgress = 100; return finish() }
        guard !sample.buffering, sample.elapsed >= 5 else { return nil }
        let action: TraktScrobbleAction = sample.playing ? .start : .pause
        guard action != lastAction, sample.playing || lastAction != nil else { return nil }
        lastAction = action
        return TraktScrobbleEvent(sessionID: sessionID, action: action, progress: lastProgress)
    }

    public mutating func finish() -> TraktScrobbleEvent? {
        guard !finished, lastAction != nil else { return nil }
        finished = true
        lastAction = .stop
        return TraktScrobbleEvent(sessionID: sessionID, action: .stop, progress: lastProgress)
    }
}
#endif
