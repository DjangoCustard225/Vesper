import Foundation
import Observation

public struct DetailPlaybackChoice: Sendable {
    public let id: String
    public let title: String?
    public let embedded: [StreamSource]?
    public let episode: Episode?

    public init(id: String, title: String? = nil, embedded: [StreamSource]? = nil, episode: Episode? = nil) {
        self.id = id
        self.title = title
        self.embedded = embedded
        self.episode = episode
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
    public private(set) var initialEpisode: Episode?
    public private(set) var selectingInitialEpisode = false
    public private(set) var initialEpisodeError: String?
    @ObservationIgnored private var resolvedInitialEpisode = false
    @ObservationIgnored private var userSelectedSeason = false
    @ObservationIgnored private var initialEpisodeRequestID = UUID()
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
        initialEpisode = nil
        selectingInitialEpisode = false
        initialEpisodeError = nil
        resolvedInitialEpisode = false
        initialEpisodeRequestID = UUID()
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

    public func selectSeason(_ season: Int?) {
        self.season = season
        userSelectedSeason = true
    }

    /// Run after watched-state synchronization. A user-selected season is never overwritten by a late result.
    public func selectInitialEpisode(
        history: WatchProgress,
        fetch: @MainActor (MediaItem, MetadataEnrichment?, Int) async throws -> [Episode]
    ) async {
        guard media.type == "series", !isLive else { return }
        let current = generation, request = UUID(), originalSeason = season
        let original = media, details = enrichment
        initialEpisodeRequestID = request
        selectingInitialEpisode = true
        initialEpisodeError = nil
        resolvedInitialEpisode = true
        defer {
            if generation == current, initialEpisodeRequestID == request { selectingInitialEpisode = false }
        }
        let index = WatchStatusIndex(history)
        var loaded: [Int: [Episode]] = [:]
        func fetchSeason(_ season: Int) async throws -> [Episode] {
            let values = try await fetch(original, details, season)
            loaded[season] = values
            return values
        }
        do {
            let continuing = ([resumeRecord].compactMap { $0 } + history.continueWatching).first {
                $0.media.isSameTitle(as: original) && !$0.watched && $0.duration > 0
            }
            var preferred: Episode?
            if let continuing {
                let id = continuing.playbackID(for: original)
                let known = (original.videos ?? []) + seasonEpisodes
                if let episode = UpNext.currentEpisode(media: original, videoID: id, knownEpisodes: known),
                    !index.isWatched(original, episode: episode)
                {
                    if let number = episode.season {
                        let values = try await fetchSeason(number)
                        preferred =
                            values.first {
                                $0.id == episode.id
                                    || $0.watchHistoryID(for: original)
                                        == episode.watchHistoryID(for: original)
                            } ?? episode
                    } else {
                        preferred = episode
                    }
                }
            }
            if preferred == nil {
                preferred = try await UpNext.firstUnwatched(
                    seasons: seasons, isWatched: { index.isWatched(original, episode: $0) },
                    fetchSeason: { number in
                        if let cached = loaded[number] { return cached }
                        return try await fetchSeason(number)
                    })
                // Some add-ons expose custom episode IDs without season numbering.
                if seasons.isEmpty {
                    preferred = (original.videos ?? []).first {
                        !$0.id.isEmpty && !index.isWatched(original, episode: $0)
                    }
                }
            }
            guard !Task.isCancelled, generation == current, initialEpisodeRequestID == request,
                enrichment?.reference == details?.reference
            else { return }
            initialEpisode = preferred
            resolvedInitialEpisode = preferred != nil || !seasons.isEmpty || !(original.videos ?? []).isEmpty
            if !userSelectedSeason, season == originalSeason, let preferred, let number = preferred.season {
                season = number
                if details?.mediaType == "tv", let values = loaded[number] {
                    seasonRequestID = UUID()
                    seasonEpisodes = values
                    seasonLoading = false
                    seasonError = nil
                }
            }
        } catch is CancellationError {} catch {
            if generation == current, initialEpisodeRequestID == request {
                initialEpisodeError = error.localizedDescription
            }
        }
    }

    private func playback(for episode: Episode) -> DetailPlaybackChoice {
        DetailPlaybackChoice(
            id: episode.id, title: episode.label + " · " + episode.displayTitle,
            embedded: episode.streams, episode: episode)
    }

    public func defaultPlayback() -> DetailPlaybackChoice? {
        if media.type == "series", !isLive {
            guard !selectingInitialEpisode, initialEpisodeError == nil else { return nil }
            if let initialEpisode { return playback(for: initialEpisode) }
            if resolvedInitialEpisode { return nil }
        }
        let rawID = media.behaviorHints?.defaultVideoId ?? media.playbackID
        let id = isLive ? media.id : MediaIdentity.videoID(rawID, for: media)
        let episode = media.videos?.first { $0.id == id }
        return DetailPlaybackChoice(
            id: id, title: episode.map { $0.label + " · " + $0.displayTitle },
            embedded: episode?.streams, episode: episode)
    }

    public func requestedPlayback() -> DetailPlaybackChoice? {
        guard startPlayback, !didStartPlayback, !loading, !enriching, !selectingInitialEpisode,
            initialEpisodeError == nil, error == nil, metadataError == nil
        else { return nil }
        let choice: DetailPlaybackChoice?
        if media.type == "series", !isLive, resolvedInitialEpisode {
            choice = initialEpisode.map(playback)
        } else if let resumeRecord {
            let id = resumeRecord.playbackID(for: media)
            let episode = (media.videos ?? []).first { MediaIdentity.videoID($0.id, for: media) == id }
            choice = DetailPlaybackChoice(
                id: id, title: resumeRecord.subtitle, embedded: episode?.streams, episode: episode)
        } else if media.type != "series" || isLive || media.behaviorHints?.defaultVideoId != nil {
            choice = defaultPlayback()
        } else {
            choice = episodes.first.map(playback)
        }
        if choice != nil { didStartPlayback = true }
        return choice
    }
}
