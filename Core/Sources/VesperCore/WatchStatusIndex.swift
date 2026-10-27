/// A derived, in-memory lookup for poster and episode badges. It never changes persisted history.
struct WatchStatusIndex: Sendable {
    private struct Entry: Sendable {
        let order: Int
        let watched: Bool
    }

    private struct Title: Sendable {
        var watched = false
        var hasEpisodeReset = false
        var movieEpisode: Entry?
        var episodes: [String: Entry] = [:]
    }

    private var titles: [String: Title] = [:]

    init(_ progress: WatchProgress = WatchProgress()) {
        for (order, record) in progress.records.enumerated() {
            let entry = Entry(order: order, watched: record.watched)
            let key = record.videoID.map(Self.episodeKey)
            for alias in MediaIdentity.aliases(record.media) {
                if record.watched && (record.media.type == "movie" || record.videoID == nil) {
                    titles[alias, default: Title()].watched = true
                }
                if record.isManualUnwatched { titles[alias, default: Title()].hasEpisodeReset = true }
                if record.media.type == "movie", record.videoID != nil,
                    titles[alias, default: Title()].movieEpisode == nil
                {
                    titles[alias, default: Title()].movieEpisode = entry
                }
                if let key, titles[alias, default: Title()].episodes[key] == nil {
                    titles[alias, default: Title()].episodes[key] = entry
                }
            }
        }
    }

    func isWatched(_ media: MediaItem, episode: Episode? = nil) -> Bool {
        let matches = MediaIdentity.aliases(media).compactMap { titles[$0] }
        if let episode {
            let keys = Set([Self.episodeKey(episode.id), Self.episodeKey(episode.watchHistoryID(for: media))])
            var first: Entry?
            for title in matches {
                let candidates =
                    media.type == "movie"
                    ? [title.movieEpisode].compactMap { $0 }
                    : keys.compactMap { title.episodes[$0] }
                for candidate in candidates where candidate.order < (first?.order ?? Int.max) {
                    first = candidate
                }
            }
            if let first { return first.watched }
        }
        return matches.contains(where: \.watched)
            && (episode != nil || !matches.contains(where: \.hasEpisodeReset))
    }

    private static func episodeKey(_ videoID: String) -> String {
        if let position = WatchRecord.episodeKey(for: videoID) { return "episode:" + position }
        return "raw:" + videoID
    }
}
