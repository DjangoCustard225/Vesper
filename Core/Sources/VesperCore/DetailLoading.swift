import Foundation
import Observation

public struct DetailPlaybackChoice: Sendable {
    public let id: String
    public let title: String?
    public let embedded: [StreamSource]?

    public init(id: String, title: String? = nil, embedded: [StreamSource]? = nil) {
        self.id = id
        self.title = title
        self.embedded = embedded
    }
}

@MainActor @Observable
public final class DetailLoadingController {
    public let item: MediaItem
    public private(set) var full: MediaItem?
    public private(set) var loading = false
    public private(set) var error: String?
    public var season: Int?
    public private(set) var enrichment: MetadataEnrichment?
    public private(set) var enriching = false
    public private(set) var metadataError: String?
    public private(set) var seasonLoading = false
    public private(set) var seasonError: String?
    public private(set) var seasonEpisodes: [Episode] = []
    @ObservationIgnored private let startPlayback: Bool
    @ObservationIgnored private let resumeRecord: WatchRecord?
    @ObservationIgnored private var didStartPlayback = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var enrichmentRequestID = UUID()
    @ObservationIgnored private var seasonRequestID = UUID()

    public init(item: MediaItem, startPlayback: Bool = false, resumeRecord: WatchRecord? = nil) {
        self.item = item
        self.startPlayback = startPlayback
        self.resumeRecord = resumeRecord
    }

    public var media: MediaItem { full ?? item }

    public var isLive: Bool { media.type == "tv" || media.behaviorHints?.isLive == true }

    public var seasons: [Int] {
        if let enrichment, !enrichment.seasons.isEmpty { return enrichment.seasons }
        return Array(Set((media.videos ?? []).compactMap(\.season))).sorted()
    }

    public var episodes: [Episode] {
        (enrichment?.mediaType == "tv" ? seasonEpisodes : media.videos ?? [])
            .filter { season == nil || $0.season == season }
            .sorted {
                if $0.season != $1.season { return ($0.season ?? 0) < ($1.season ?? 0) }
                return ($0.episode ?? 0) < ($1.episode ?? 0)
            }
    }

    public func load(
        metadata: @MainActor (MediaItem) async -> (MediaItem, String?),
        enrich: (@MainActor (MediaItem) async throws -> MetadataEnrichment?)? = nil
    ) async {
        generation = UUID()
        let current = generation
        loading = true
        defer { if generation == current { loading = false } }
        error = nil
        full = nil
        enrichment = nil
        enriching = false
        metadataError = nil
        enrichmentRequestID = UUID()
        seasonRequestID = UUID()
        seasonEpisodes = []
        seasonLoading = false
        seasonError = nil
        let (result, failure) = await metadata(item)
        guard !Task.isCancelled, generation == current else { return }
        full = result
        error = failure
        loading = false
        if season == nil { season = resumeRecord?.season }
        if season == nil { season = seasons.first(where: { $0 > 0 }) ?? seasons.first }
        if let enrich { await refreshEnrichment(using: enrich) }
    }

    public func refreshEnrichment(using fetch: @MainActor (MediaItem) async throws -> MetadataEnrichment?)
        async
    {
        guard media.type == "movie" || media.type == "series" else { return }
        let current = generation, request = UUID(), original = media
        enrichmentRequestID = request
        enriching = true
        metadataError = nil
        defer {
            if generation == current && enrichmentRequestID == request { enriching = false }
        }
        do {
            let result = try await fetch(original)
            guard !Task.isCancelled, generation == current, enrichmentRequestID == request else { return }
            enrichment = result
            if let result {
                full = result.applying(to: original)
                if season.map({ !result.seasons.contains($0) }) ?? true {
                    season = result.seasons.first(where: { $0 > 0 }) ?? result.seasons.first
                }
            }
        } catch is CancellationError { return } catch {
            if generation == current && enrichmentRequestID == request {
                metadataError = error.localizedDescription
            }
        }
    }

    public func loadSeason(
        preserveExisting: Bool = false,
        fetch: @MainActor (MediaItem, MetadataEnrichment, Int) async throws -> [Episode]
    ) async {
        let current = generation, request = UUID()
        seasonRequestID = request
        if !preserveExisting { seasonEpisodes = [] }
        seasonError = nil
        seasonLoading = false
        guard let enrichment, enrichment.mediaType == "tv", let season else { return }
        seasonLoading = true
        defer {
            if generation == current && seasonRequestID == request { seasonLoading = false }
        }
        do {
            let videos = try await fetch(media, enrichment, season)
            guard !Task.isCancelled, generation == current, seasonRequestID == request,
                self.season == season, self.enrichment?.reference == enrichment.reference
            else { return }
            seasonEpisodes = videos
        } catch is CancellationError { return } catch {
            if generation == current && seasonRequestID == request {
                seasonError = error.localizedDescription
            }
        }
    }

    public func defaultPlayback() -> DetailPlaybackChoice {
        let rawID = media.behaviorHints?.defaultVideoId ?? media.playbackID
        let id = isLive ? media.id : MediaIdentity.videoID(rawID, for: media)
        let episode = media.videos?.first { $0.id == id }
        return DetailPlaybackChoice(
            id: id, title: episode.map { $0.label + " · " + $0.displayTitle },
            embedded: episode?.streams)
    }

    public func requestedPlayback() -> DetailPlaybackChoice? {
        guard startPlayback, !didStartPlayback, !loading, !enriching, error == nil, metadataError == nil
        else {
            return nil
        }
        if let resumeRecord {
            didStartPlayback = true
            let id = resumeRecord.playbackID(for: media)
            let episode = (media.videos ?? []).first { MediaIdentity.videoID($0.id, for: media) == id }
            return DetailPlaybackChoice(id: id, title: resumeRecord.subtitle, embedded: episode?.streams)
        }
        if media.type != "series" || isLive || media.behaviorHints?.defaultVideoId != nil {
            didStartPlayback = true
            return defaultPlayback()
        }
        if let episode = episodes.first {
            didStartPlayback = true
            return DetailPlaybackChoice(
                id: episode.id, title: episode.label + " · " + episode.displayTitle,
                embedded: episode.streams)
        }
        return nil
    }
}
