import Foundation

public struct WatchRecord: Codable, Identifiable, Sendable {
    public let media: MediaItem
    public let videoID: String?
    public let subtitle: String?
    public let elapsed: Double
    public let duration: Double
    public let watched: Bool
    public let updatedAt: Date
    public var importedFromTrakt: Bool? = nil
    public var hiddenFromContinueWatching: Bool? = nil

    public var id: String { media.key + ":" + (videoID ?? "watched") }

    // A show's episode identity remains stable when TMDB enrichment adds an IMDb ID.
    public var episodeKey: String? {
        guard media.type == "series", let videoID else { return nil }
        return Self.episodeKey(for: videoID)
    }

    static func episodeKey(for videoID: String) -> String? {
        let parts = videoID.split(separator: ":")
        guard parts.count >= 3, let season = Int(parts[parts.count - 2]), season >= 0,
            let episode = Int(parts[parts.count - 1]), episode > 0
        else { return nil }
        return "\(season):\(episode)"
    }

    public var season: Int? { episodeKey.flatMap { Int($0.split(separator: ":")[0]) } }

    // A manual episode reset records an explicit choice without inventing playback timing.
    var isManualUnwatched: Bool { media.type == "series" && videoID != nil && !watched && duration == 0 }

    public func playbackID(for item: MediaItem) -> String {
        if let episodeKey { return item.playbackID + ":" + episodeKey }
        return videoID.map { MediaIdentity.videoID($0, for: item) } ?? item.playbackID
    }

    fileprivate func matches(videoID: String, media: MediaItem) -> Bool {
        guard self.media.isSameTitle(as: media), self.videoID != nil else { return false }
        if media.type == "movie" { return true }
        let candidate = WatchRecord(
            media: media, videoID: videoID, subtitle: nil,
            elapsed: 0, duration: 0, watched: false, updatedAt: .distantPast)
        if let episodeKey, let other = candidate.episodeKey { return episodeKey == other }
        return self.videoID == videoID
    }
}

public struct WatchProgress: Codable, Sendable {
    public private(set) var records: [WatchRecord] = []

    public init() {}

    public var continueWatching: [WatchRecord] {
        var result: [WatchRecord] = []
        var hiddenAliases = Set<String>()
        for record in records where record.watched && (record.media.type == "movie" || record.videoID == nil)
        {
            hiddenAliases.formUnion(MediaIdentity.aliases(record.media))
        }
        for record in records.sorted(by: { $0.updatedAt > $1.updatedAt })
        where record.videoID != nil && !record.watched && record.duration > 0
            && record.hiddenFromContinueWatching != true
        {
            let aliases = MediaIdentity.aliases(record.media)
            guard aliases.isDisjoint(with: hiddenAliases) else { continue }
            hiddenAliases.formUnion(aliases)
            result.append(record)
        }
        return result
    }

    public mutating func removeFromContinueWatching(for media: MediaItem) {
        for index in records.indices
        where records[index].media.isSameTitle(as: media) && !records[index].watched {
            records[index].hiddenFromContinueWatching = true
        }
    }

    public func isWatched(_ media: MediaItem, episode: Episode? = nil) -> Bool {
        if let episode,
            let record = records.first(where: {
                $0.matches(videoID: episode.id, media: media)
                    || $0.matches(videoID: episode.watchHistoryID(for: media), media: media)
            })
        {
            return record.watched
        }
        let wholeTitleWatched = records.contains {
            $0.media.isSameTitle(as: media) && $0.watched && (media.type == "movie" || $0.videoID == nil)
        }
        if episode != nil { return wholeTitleWatched }
        return wholeTitleWatched
            && !records.contains {
                $0.media.isSameTitle(as: media) && $0.isManualUnwatched
            }
    }

    public func resumePosition(for media: MediaItem, videoID: String) -> Double {
        guard !isWatched(media),
            let record = records.first(where: { $0.matches(videoID: videoID, media: media) }),
            !record.watched
        else { return 0 }
        return record.elapsed
    }

    public mutating func setWatched(
        _ watched: Bool, for media: MediaItem, episode: Episode? = nil, now: Date = Date()
    ) {
        guard Self.supports(media) else { return }
        if let episode {
            guard media.type == "series", !episode.id.isEmpty else { return }
            let videoID = episode.watchHistoryID(for: media)
            records.removeAll {
                $0.matches(videoID: episode.id, media: media) || $0.matches(videoID: videoID, media: media)
            }
            records.insert(
                WatchRecord(
                    media: Self.compact(media), videoID: videoID, subtitle: episode.displayTitle,
                    elapsed: 0, duration: 0, watched: watched, updatedAt: now), at: 0)
            trim()
            return
        }
        records.removeAll { $0.media.isSameTitle(as: media) }
        if watched {
            records.insert(
                WatchRecord(
                    media: Self.compact(media), videoID: nil, subtitle: nil,
                    elapsed: 0, duration: 0, watched: true, updatedAt: now), at: 0)
        }
        trim()
    }

    @discardableResult public mutating func record(
        media: MediaItem, videoID: String, subtitle: String?,
        elapsed: Double, duration: Double, ended: Bool = false,
        now: Date = Date()
    ) -> Bool {
        guard Self.supports(media), !videoID.isEmpty, elapsed.isFinite, duration.isFinite,
            duration > 0, elapsed >= 0, elapsed >= 5 || ended
        else { return false }
        let elapsed = min(elapsed, duration)
        let watched = ended || elapsed / duration >= 0.95
        records.removeAll {
            $0.media.isSameTitle(as: media)
                && ($0.videoID == nil || $0.matches(videoID: videoID, media: media))
        }
        records.insert(
            WatchRecord(
                media: Self.compact(media), videoID: videoID, subtitle: subtitle,
                elapsed: elapsed, duration: duration, watched: watched, updatedAt: now), at: 0)
        trim()
        return true
    }

    public static func supports(_ media: MediaItem) -> Bool {
        (media.type == "movie" || media.type == "series") && media.behaviorHints?.isLive != true
    }

    /// Remote watched state never supplies fabricated resume positions. Newer local rewatches win.
    public mutating func mergeTrakt(
        _ entries: [TraktWatchedEntry], pending: [TraktHistoryChange] = []
    ) {
        var artwork: [String: MediaItem] = [:]
        for record in records {
            for alias in MediaIdentity.aliases(record.media) where artwork[alias] == nil {
                artwork[alias] = record.media
            }
        }
        let local = records.filter { $0.importedFromTrakt != true }
        var localIndices: [String: Set<Int>] = [:]
        var pendingIndices: [String: Set<Int>] = [:]
        for (index, record) in local.enumerated() {
            for alias in MediaIdentity.aliases(record.media) {
                localIndices[alias, default: []].insert(index)
            }
        }
        for (index, change) in pending.enumerated() {
            for alias in MediaIdentity.aliases(change.media) {
                pendingIndices[alias, default: []].insert(index)
            }
        }
        var removed = Set<Int>()
        var imported: [WatchRecord] = []
        var seen = Set<String>()
        // Match by pre-indexed IDs and keep the existing 2,000-record bound, even for huge Trakt accounts.
        for entry in entries.sorted(by: { $0.watchedAt > $1.watchedAt }).prefix(2_000) {
            guard Self.supports(entry.media) else { continue }
            let aliases = MediaIdentity.aliases(entry.media)
            let episode = entry.videoID.flatMap(TraktClient.episode).map { "\($0.season):\($0.number)" }
            let targetAliases = Set(aliases.map { $0 + ":" + (episode ?? "watched") })
            guard seen.isDisjoint(with: targetAliases) else { continue }
            seen.formUnion(targetAliases)
            let edits = Set(aliases.flatMap { pendingIndices[$0] ?? [] })
            guard
                !edits.contains(where: { index in
                    let change = pending[index]
                    if entry.media.type == "movie" || change.videoID == nil || entry.videoID == nil {
                        return true
                    }
                    return TraktClient.episode(change.videoID).map { "\($0.season):\($0.number)" } == episode
                })
            else { continue }
            let candidates = Set(aliases.flatMap { localIndices[$0] ?? [] }).subtracting(removed)
            let matches: (Int) -> Bool = { index in
                if entry.media.type == "movie" { return true }
                if entry.videoID == nil { return local[index].videoID == nil }
                return episode.map { local[index].episodeKey == $0 }
                    ?? (local[index].videoID == entry.videoID)
            }
            guard
                !candidates.contains(where: {
                    local[$0].updatedAt > entry.watchedAt.addingTimeInterval(1)
                        && (entry.videoID == nil || matches($0))
                })
            else { continue }
            let media = aliases.sorted().compactMap { artwork[$0] }.first ?? entry.media
            removed.formUnion(candidates.filter(matches))
            var record = WatchRecord(
                media: Self.compact(media), videoID: entry.videoID, subtitle: nil,
                elapsed: 0, duration: 0, watched: true, updatedAt: entry.watchedAt)
            record.importedFromTrakt = true
            imported.append(record)
        }
        records = local.indices.filter { !removed.contains($0) }.map { local[$0] } + imported
        records.sort { $0.updatedAt > $1.updatedAt }
        trim()
    }

    /// Replaces imported episode state for one title and retains imports for other titles.
    public mutating func replaceTraktHistory(
        for media: MediaItem, with entries: [TraktWatchedEntry], pending: [TraktHistoryChange] = []
    ) {
        guard media.type == "series" else { return }
        let otherImports = records.filter {
            $0.importedFromTrakt == true && !$0.media.isSameTitle(as: media)
        }
        mergeTrakt(entries.filter { $0.media.isSameTitle(as: media) }, pending: pending)
        let existingIDs = Set(records.map(\.id))
        records.append(contentsOf: otherImports.filter { !existingIDs.contains($0.id) })
        records.sort { $0.updatedAt > $1.updatedAt }
        trim()
    }

    public mutating func detachTrakt() {
        for index in records.indices { records[index].importedFromTrakt = nil }
    }

    private static func compact(_ media: MediaItem) -> MediaItem {
        var result = media
        result.videos = nil
        result.behaviorHints = nil
        result.description = nil
        result.cast = nil
        result.director = nil
        return result
    }

    private mutating func trim() { records = Array(records.prefix(2_000)) }

    var isValid: Bool {
        records.count <= 2_000
            && records.allSatisfy {
                Self.supports($0.media) && !$0.media.id.isEmpty && !$0.media.name.isEmpty
                    && $0.media.videos == nil && $0.elapsed.isFinite && $0.duration.isFinite
                    && $0.elapsed >= 0 && $0.duration >= 0 && $0.elapsed <= $0.duration
                    && ($0.videoID == nil
                        ? $0.watched
                        : ($0.videoID != "" && ($0.duration > 0 || $0.watched || $0.isManualUnwatched)))
            }
    }
}
