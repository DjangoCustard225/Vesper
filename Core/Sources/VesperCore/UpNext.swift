import Foundation

/// Uses episode order and exact playback identities, including add-on-specific IDs.
@MainActor public enum UpNext {
    public struct Seed: Hashable, Sendable {
        public let media: MediaItem
        public let episode: Episode
        public let updatedAt: Date
    }

    /// The latest activity for a show wins. An unfinished episode or whole-show mark blocks older plays.
    public static func homeSeeds(in history: WatchProgress, limit: Int = 20) -> [Seed] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [Seed] = []
        for record in history.records.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard record.media.type == "series", WatchProgress.supports(record.media) else { continue }
            let aliases = MediaIdentity.aliases(record.media)
            let alreadySeen = !seen.isDisjoint(with: aliases)
            seen.formUnion(aliases)
            guard !alreadySeen, record.watched, let videoID = record.videoID else { continue }
            guard record.hiddenFromContinueWatching != true else { continue }
            guard
                let episode = currentEpisode(
                    media: record.media, videoID: videoID, knownEpisodes: record.media.videos ?? [])
            else { continue }
            result.append(Seed(media: record.media, episode: episode, updatedAt: record.updatedAt))
            if result.count == limit { break }
        }
        return result
    }

    public static func currentEpisode(
        media: MediaItem, videoID: String, episode: Episode? = nil, knownEpisodes: [Episode] = []
    ) -> Episode? {
        guard media.type == "series", WatchProgress.supports(media) else { return nil }
        let normalized = MediaIdentity.videoID(videoID, for: media)
        if let match = ([episode].compactMap { $0 } + knownEpisodes).first(where: {
            $0.id == videoID || MediaIdentity.videoID($0.id, for: media) == normalized
                || $0.watchHistoryID(for: media) == normalized
        }) {
            return match
        }
        let prefix = media.playbackID + ":"
        guard normalized.hasPrefix(prefix) else { return nil }
        let parts = normalized.dropFirst(prefix.count).split(separator: ":")
        guard parts.count == 2, let season = Int(parts[0]), season >= 0,
            let number = Int(parts[1]), number > 0
        else { return nil }
        return Episode(
            id: videoID, title: nil, name: nil, season: season, episode: number, overview: nil,
            thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
    }

    public static func resolve(
        after current: Episode, seasons: [Int], now: Date = Date(),
        isWatched: @MainActor (Episode) -> Bool,
        fetchSeason: @MainActor (Int) async throws -> [Episode]
    ) async throws -> Episode? {
        guard let season = current.season, season >= 0, let number = current.episode, number > 0 else {
            return nil
        }
        // Specials have no reliable place in normal season chronology. Continue within specials only.
        let remainingSeasons = Set(seasons + [season]).filter {
            season == 0 ? $0 == 0 : $0 >= season && $0 > 0
        }.sorted()
        for nextSeason in remainingSeasons {
            try Task.checkCancellation()
            let episodes = try await fetchSeason(nextSeason)
            try Task.checkCancellation()
            var seen = Set<Int>()
            for candidate in episodes.sorted(by: {
                if $0.episode != $1.episode { return ($0.episode ?? 0) < ($1.episode ?? 0) }
                return $0.id < $1.id
            }) {
                guard candidate.season == nextSeason, let nextNumber = candidate.episode, nextNumber > 0,
                    nextSeason > season || nextNumber > number,
                    !candidate.id.isEmpty, candidate.id != current.id,
                    seen.insert(nextNumber).inserted, !isWatched(candidate)
                else { continue }
                // Do not jump past an unaired episode into later episodes with missing dates.
                guard hasAired(candidate, now: now) else { return nil }
                return candidate
            }
        }
        return nil
    }

    public static func shouldOffer(timeline: PlaybackTimeline, ended: Bool) -> Bool {
        ended
            || (timeline.isSeekable && timeline.duration > 0
                && timeline.remaining <= min(30, timeline.duration * 0.05))
    }

    private static func hasAired(_ episode: Episode, now: Date) -> Bool {
        guard let value = episode.released, !value.isEmpty else { return true }
        if let date = TraktDates.parse(value) { return date <= now }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard value.count == 10, let date = formatter.date(from: value) else { return false }
        return date <= now
    }
}
