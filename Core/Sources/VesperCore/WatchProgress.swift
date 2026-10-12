import Foundation

public struct WatchRecord: Codable, Identifiable, Sendable {
    public let media: MediaItem
    public let videoID: String?
    public let subtitle: String?
    public let elapsed: Double
    public let duration: Double
    public let watched: Bool
    public let updatedAt: Date
    public var id: String { media.key + ":" + (videoID ?? "watched") }

    // A show's episode identity remains stable when TMDB enrichment adds an IMDb ID.
    public var episodeKey: String? {
        guard media.type == "series", let videoID else { return nil }
        let parts = videoID.split(separator: ":")
        guard parts.count >= 3, let season = Int(parts[parts.count - 2]), season >= 0,
              let episode = Int(parts[parts.count - 1]), episode > 0 else { return nil }
        return "\(season):\(episode)"
    }
    public var season: Int? { episodeKey.flatMap { Int($0.split(separator: ":")[0]) } }
    public func playbackID(for item: MediaItem) -> String {
        if let episodeKey { return item.playbackID + ":" + episodeKey }
        return videoID.map { MediaIdentity.videoID($0, for: item) } ?? item.playbackID
    }
    fileprivate func matches(videoID: String, media: MediaItem) -> Bool {
        guard self.media.isSameTitle(as: media), self.videoID != nil else { return false }
        if media.type == "movie" { return true }
        let candidate = WatchRecord(media: media, videoID: videoID, subtitle: nil,
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
        for record in records where record.watched && (record.media.type == "movie" || record.videoID == nil) {
            hiddenAliases.formUnion(MediaIdentity.aliases(record.media))
        }
        for record in records.sorted(by: { $0.updatedAt > $1.updatedAt }) where record.videoID != nil && !record.watched {
            let aliases = MediaIdentity.aliases(record.media)
            guard aliases.isDisjoint(with: hiddenAliases) else { continue }
            hiddenAliases.formUnion(aliases)
            result.append(record)
        }
        return result
    }

    public func isWatched(_ media: MediaItem) -> Bool {
        records.contains { $0.media.isSameTitle(as: media) && $0.watched && (media.type == "movie" || $0.videoID == nil) }
    }

    public func resumePosition(for media: MediaItem, videoID: String) -> Double {
        guard !isWatched(media), let record = records.first(where: { $0.matches(videoID: videoID, media: media) }),
              !record.watched else { return 0 }
        return record.elapsed
    }

    public mutating func setWatched(_ watched: Bool, for media: MediaItem, now: Date = Date()) {
        guard Self.supports(media) else { return }
        records.removeAll { $0.media.isSameTitle(as: media) }
        if watched {
            records.insert(WatchRecord(media: Self.compact(media), videoID: nil, subtitle: nil,
                                       elapsed: 0, duration: 0, watched: true, updatedAt: now), at: 0)
        }
        trim()
    }

    @discardableResult public mutating func record(media: MediaItem, videoID: String, subtitle: String?,
                                                  elapsed: Double, duration: Double, ended: Bool = false,
                                                  now: Date = Date()) -> Bool {
        guard Self.supports(media), !videoID.isEmpty, elapsed.isFinite, duration.isFinite,
              duration > 0, elapsed >= 0, elapsed >= 5 || ended else { return false }
        let elapsed = min(elapsed, duration)
        let watched = ended || elapsed / duration >= 0.95
        records.removeAll { $0.media.isSameTitle(as: media) && ($0.videoID == nil || $0.matches(videoID: videoID, media: media)) }
        records.insert(WatchRecord(media: Self.compact(media), videoID: videoID, subtitle: subtitle,
                                   elapsed: elapsed, duration: duration, watched: watched, updatedAt: now), at: 0)
        trim()
        return true
    }

    public static func supports(_ media: MediaItem) -> Bool {
        (media.type == "movie" || media.type == "series") && media.behaviorHints?.isLive != true
    }
    private static func compact(_ media: MediaItem) -> MediaItem {
        var result = media
        result.videos = nil; result.behaviorHints = nil
        result.description = nil; result.cast = nil; result.director = nil
        return result
    }
    private mutating func trim() { records = Array(records.prefix(2_000)) }

    var isValid: Bool {
        records.count <= 2_000 && records.allSatisfy {
            Self.supports($0.media) && !$0.media.id.isEmpty && !$0.media.name.isEmpty &&
            $0.media.videos == nil && $0.elapsed.isFinite && $0.duration.isFinite &&
            $0.elapsed >= 0 && $0.duration >= 0 && $0.elapsed <= $0.duration &&
            ($0.videoID == nil ? $0.watched : ($0.videoID != "" && $0.duration > 0))
        }
    }
}
