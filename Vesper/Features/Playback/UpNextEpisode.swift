import VesperCore

extension AppStore {
    func nextEpisode(
        for media: MediaItem, video: VideoSelection, knownEpisodes: [Episode],
        details: MetadataEnrichment?
    ) async throws -> Episode? {
        let known = knownEpisodes + (media.videos ?? [])
        guard
            let current = UpNext.currentEpisode(
                media: media, videoID: video.id, episode: video.episode, knownEpisodes: known)
        else { return nil }
        return try await nextEpisode(for: media, after: current, knownEpisodes: known, details: details)
    }
}

extension AppStore {
    func nextEpisode(
        for media: MediaItem, after current: Episode, knownEpisodes: [Episode],
        details: MetadataEnrichment?
    ) async throws -> Episode? {
        let revision = metadataConfigurationRevision
        var details = details
        if details == nil, hasMetadata(for: media) {
            do { details = try await enrichedMetadata(for: media) } catch is CancellationError {
                throw CancellationError()
            } catch { if knownEpisodes.isEmpty { throw error } }
        }
        try Task.checkCancellation()
        guard revision == metadataConfigurationRevision else { throw CancellationError() }
        return try await UpNext.resolve(
            after: current, seasons: (details?.seasons ?? []) + knownEpisodes.compactMap(\.season),
            isWatched: { self.isWatched(media, episode: $0) }
        ) { season in
            let episodes: [Episode]
            if let details {
                episodes = try await self.episodes(for: media, details: details, season: season)
            } else {
                episodes = knownEpisodes.filter { $0.season == season }
            }
            guard revision == self.metadataConfigurationRevision else { throw CancellationError() }
            return episodes
        }
    }
}
