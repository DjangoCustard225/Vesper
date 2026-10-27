import Foundation

/// A delayed PiP teardown must never deactivate a newer player's shared audio session.
@MainActor enum PlaybackAudioOwnership {
    private static var current: UUID?

    static func acquire() -> UUID {
        let lease = UUID()
        current = lease
        return lease
    }

    static func release(_ lease: UUID) -> Bool {
        guard current == lease else { return false }
        current = nil
        return true
    }
}

struct PlaybackTrack: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
}

enum PlaybackSpeed {
    static let values: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static let boost: Float = 2
}
