import Foundation
import VesperCore

typealias PlaybackRestoration = @MainActor (@escaping @MainActor (Bool) -> Void) -> Void

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let subtitle: String?
    var isLive = false
    var resumeSeconds: Double = 0
    var onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)? = nil
    var onScrobble: (@MainActor (TraktScrobbleEvent) -> Void)? = nil
    var loadUpNext: (@MainActor () async throws -> Episode?)? = nil
    var onNextEpisode: (@MainActor (Episode) -> Void)? = nil
    var loadIntroSegment: (@MainActor () async throws -> IntroSegment?)? = nil
    var introSkippingEnabled: @MainActor () -> Bool = { true }
}
