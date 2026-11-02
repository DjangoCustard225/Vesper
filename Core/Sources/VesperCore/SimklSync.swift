import Foundation

public struct SimklSyncState: Codable, Sendable {
    public var accountID: String?
    public var activities: Data?
    public var items: [String: Data] = [:]
    public var pending: [TraktHistoryChange] = []
    public var lastSyncedAt: Date?
    public init() {}

    public mutating func enqueue(_ change: TraktHistoryChange) throws {
        _ = try SimklClient.identity(change.media)
        pending.removeAll { old in
            old.media.isSameTitle(as: change.media)
                && (change.videoID == nil || old.videoID == change.videoID)
        }
        guard pending.count < 500 else { throw SimklError.response }
        pending.append(change)
    }

    public mutating func apply(_ data: Data, replacing: Bool = false) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["movies"] is [Any] || root["shows"] is [Any]
        else { throw SimklError.response }
        if replacing { items = [:] }
        for kind in ["movies", "shows"] {
            for row in root[kind] as? [[String: Any]] ?? [] {
                let media = row[kind == "movies" ? "movie" : "show"] as? [String: Any] ?? [:]
                let ids = media["ids"] as? [String: Any] ?? [:]
                guard let id = ids["simkl"], !(id is NSNull) else { throw SimklError.response }
                items[kind + ":" + String(describing: id)] = try JSONSerialization.data(withJSONObject: row)
            }
        }
    }

    public func entries() throws -> [TraktWatchedEntry] {
        try items.flatMap { key, data -> [TraktWatchedEntry] in
            let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let movie = key.hasPrefix("movies:")
            let object = row[movie ? "movie" : "show"] as? [String: Any] ?? [:]
            let ids = object["ids"] as? [String: Any] ?? [:]
            func number(_ key: String) -> Int? { ids[key].flatMap { Int(String(describing: $0)) } }
            let imdb = MediaIdentity.validIMDb(ids["imdb"] as? String)
            let tmdb = number("tmdb"), tvdb = number("tvdb")
            guard let id = imdb ?? tmdb.map({ "tmdb:\($0)" }) ?? tvdb.map({ "tvdb:\($0)" }) else { return [] }
            var media = MediaItem(
                id: id, type: movie ? "movie" : "series", name: object["title"] as? String ?? "")
            media.imdbID = imdb; media.tmdbID = tmdb; media.tvdbID = tvdb
            func date(_ value: Any?) -> Date { (value as? String).flatMap(TraktDates.parse) ?? .distantPast }
            if movie {
                guard row["status"] as? String == "completed" else { return [] }
                return [TraktWatchedEntry(media: media, watchedAt: date(row["last_watched_at"]))]
            }
            return (row["seasons"] as? [[String: Any]] ?? []).flatMap { season in
                guard let n = season["number"] as? Int, n >= 0 else { return [TraktWatchedEntry]() }
                return (season["episodes"] as? [[String: Any]] ?? []).compactMap { episode in
                    guard let e = episode["number"] as? Int, e > 0 else { return nil }
                    return TraktWatchedEntry(
                        media: media, videoID: "\(media.playbackID):\(n):\(e)",
                        watchedAt: date(episode["watched_at"] ?? row["last_watched_at"]))
                }
            }
        }
    }
}

public struct SimklSyncRepository: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> SimklSyncState {
        guard FileManager.default.fileExists(atPath: url.path) else { return SimklSyncState() }
        return try JSONDecoder().decode(
            SimklSyncState.self, from: PersistenceIO.read(url, maximumBytes: 64 * 1024 * 1024))
    }
    public func save(_ state: SimklSyncState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        guard data.count <= 64 * 1024 * 1024 else { throw SimklError.response }
        try PersistenceIO.write(data, url)
    }
}
