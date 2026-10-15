import Observation
import VesperCore

/// Shared controls depend on playback behavior, while each engine owns its rendering and lifecycle.
@MainActor protocol PlaybackControlling: AnyObject, Observable {
    var timeline: PlaybackTimeline { get }

    var isPlaying: Bool { get }

    var isBuffering: Bool { get }

    var hasEnded: Bool { get }

    var error: String? { get }

    var audioTracks: [PlaybackTrack] { get }

    var subtitleTracks: [PlaybackTrack] { get }

    var selectedAudio: Int32 { get }

    var selectedSubtitle: Int32 { get }

    var speed: Float { get }

    var isBoosting: Bool { get }

    var fillsScreen: Bool { get }

    func togglePlayback()

    func pause()

    func stop()

    func seek(fraction: Double)

    func skip(seconds: Double)

    func selectAudio(_ id: Int32)

    func selectSubtitle(_ id: Int32)

    func setSpeed(_ value: Float)

    func beginBoost()

    func endBoost()

    func setFill(_ fill: Bool)
}

extension MPVPlaybackController: PlaybackControlling {}
extension AetherPlaybackController: PlaybackControlling {}
