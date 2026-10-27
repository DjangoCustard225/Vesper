import Foundation
import Observation

public struct IntroEpisode: Hashable, Sendable {
    public let imdbID: String
    public let season: Int
    public let episode: Int

    public init?(imdbID: String, season: Int, episode: Int) {
        guard MediaIdentity.validIMDb(imdbID) != nil, season >= 0, episode > 0 else { return nil }
        self.imdbID = imdbID
        self.season = season
        self.episode = episode
    }

    var key: String { "intro:v1:\(imdbID):\(season):\(episode)" }
}

public struct IntroSegment: Codable, Equatable, Sendable {
    public let startSeconds: Double
    public let endSeconds: Double

    public init?(startMilliseconds: Double, endMilliseconds: Double) {
        guard startMilliseconds.isFinite, endMilliseconds.isFinite,
            startMilliseconds >= 0, endMilliseconds > startMilliseconds
        else { return nil }
        startSeconds = startMilliseconds / 1000
        endSeconds = endMilliseconds / 1000
    }

    public func seekFraction(in timeline: PlaybackTimeline) -> Double? {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds > startSeconds,
            timeline.isSeekable, endSeconds <= timeline.duration,
            timeline.elapsed >= startSeconds, timeline.elapsed < endSeconds
        else { return nil }
        return endSeconds / timeline.duration
    }
}

/// A dismissed or superseded playback session cannot publish a late lookup.
@MainActor @Observable
public final class IntroSkipController {
    public private(set) var segment: IntroSegment?
    @ObservationIgnored private var generation = UUID()

    public init() {}

    public func load(_ lookup: (@MainActor () async throws -> IntroSegment?)?) async {
        let token = UUID()
        generation = token
        segment = nil
        guard let lookup else { return }
        do {
            let result = try await lookup()
            guard generation == token, !Task.isCancelled else { return }
            segment = result
        } catch {
            // Optional segment metadata never becomes a playback error.
        }
    }

    public func cancel() {
        generation = UUID()
        segment = nil
    }
}
