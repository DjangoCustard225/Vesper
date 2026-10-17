import Foundation
import VesperCore

enum PlaybackEngine { case mpv, aether }

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let subtitle: String?
    var engine: PlaybackEngine = .mpv
    var isLive = false
    var resumeSeconds: Double = 0
    var onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)? = nil
    var onScrobble: (@MainActor (TraktScrobbleEvent) -> Void)? = nil
}
