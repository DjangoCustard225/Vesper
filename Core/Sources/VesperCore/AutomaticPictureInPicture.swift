/// Coordinates UIKit backgrounding with AVKit's animation callbacks.
/// AVKit owns entry and exit; the host keeps its video surface stable until the animation ends.
public struct AutomaticPictureInPicture: Sendable {
    public enum State: Equatable, Sendable {
        case inactive, waiting, starting, active, restoring, stopping

        public var isPresented: Bool { self != .inactive && self != .waiting }
        public var isTransitioning: Bool { self == .starting || self == .restoring || self == .stopping }
    }

    public enum BackgroundAction: Equatable, Sendable { case keepPlaying, waitForSystem, pause }
    public private(set) var state: State = .inactive

    public init() {}

    public mutating func backgrounded(eligible: Bool, externalPlayback: Bool) -> BackgroundAction {
        if externalPlayback || state.isPresented { return .keepPlaying }
        if state == .waiting { return .waitForSystem }
        guard eligible else { return .pause }
        state = .waiting
        return .waitForSystem
    }

    public mutating func willStart() { state = .starting }
    public mutating func started() { state = .active }
    public mutating func restoring() { state = .restoring }

    public mutating func restorationFailed() {
        if state == .restoring { state = .active }
    }

    public mutating func willStop() {
        if state != .restoring { state = .stopping }
    }

    /// Restoration can finish before UIKit reports the app as foregrounded.
    public mutating func stopped() -> Bool {
        let shouldPause = state != .restoring
        state = .inactive
        return shouldPause
    }

    public mutating func foregrounded() {
        if state == .waiting { state = .inactive }
    }

    public mutating func graceExpired() -> Bool {
        guard state == .waiting else { return false }
        state = .inactive
        return true
    }

    public mutating func reset() { state = .inactive }
}
