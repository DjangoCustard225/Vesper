import Foundation

struct PlaybackTrack: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
}

struct MPVSnapshot: Equatable, Sendable {
    var elapsed: Double = 0
    var duration: Double = 0
    var seekable = false
    var loaded = false
    var buffering = true
    var ended = false
    var audio: [PlaybackTrack] = []
    var subtitles: [PlaybackTrack] = []
    var selectedAudio: Int32 = -1
    var selectedSubtitle: Int32 = -1
}

enum MPVPlaybackEvent: Sendable {
    case state(MPVSnapshot)
    case failure(String)
}

enum PlaybackSpeed {
    static let values: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static let boost: Float = 2
}
