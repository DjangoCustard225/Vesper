import Foundation

public struct TraktTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int
    public let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token"
        case expiresIn = "expires_in", createdAt = "created_at"
    }

    public var expiresAt: Date { Date(timeIntervalSince1970: Double(createdAt) + Double(expiresIn)) }

    var isValid: Bool { !accessToken.isEmpty && !refreshToken.isEmpty && expiresIn > 0 }
}

public struct TraktDeviceCode: Decodable, Sendable {
    let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURL = "verification_url"
        case expiresIn = "expires_in", interval
    }

    var isValid: Bool {
        !deviceCode.isEmpty && !userCode.isEmpty && expiresIn > 0 && interval > 0
            && verificationURL.scheme == "https"
            && ["auth.trakt.tv", "trakt.tv", "app.trakt.tv"].contains(verificationURL.host ?? "")
            && verificationURL.user == nil && verificationURL.password == nil && verificationURL.port == nil
    }
}

public struct TraktAccount: Codable, Equatable, Sendable {
    public let username: String?
    public let name: String?
    public let ids: IDs?

    public struct IDs: Codable, Equatable, Sendable {
        public let slug: String?
        public let uuid: String?
    }

    public var id: String { ids?.uuid ?? ids?.slug ?? username ?? "" }
    public var displayName: String {
        [name, username, ids?.slug].compactMap { $0 }.first { !$0.isEmpty } ?? "Trakt account"
    }
}

struct TraktUserSettings: Decodable {
    let user: TraktAccount

    private enum CodingKeys: String, CodingKey { case user }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user =
            try container.contains(.user)
            ? container.decode(TraktAccount.self, forKey: .user)
            : TraktAccount(from: decoder)
    }
}

struct TraktIDs: Codable, Equatable, Sendable {
    var trakt: Int?
    var imdb: String?
    var tmdb: Int?

    init(trakt: Int? = nil, imdb: String? = nil, tmdb: Int? = nil) {
        self.trakt = trakt
        self.imdb = MediaIdentity.validIMDb(imdb)
        self.tmdb = tmdb.flatMap { $0 > 0 ? $0 : nil }
    }

    init(_ media: MediaItem) {
        let parts = media.id.split(separator: ":")
        let trakt = parts.count == 2 && parts.first == "trakt" ? Int(parts[1]) : nil
        self.init(
            trakt: trakt, imdb: MediaIdentity.validIMDb(media.imdbID) ?? MediaIdentity.validIMDb(media.id),
            tmdb: MediaIdentity.tmdbID(media))
    }

    var lookup: (type: String, value: String)? {
        if let trakt, trakt > 0 { return ("trakt", String(trakt)) }
        if let imdb = MediaIdentity.validIMDb(imdb) { return ("imdb", imdb) }
        if let tmdb, tmdb > 0 { return ("tmdb", String(tmdb)) }
        return nil
    }
}

struct TraktTitle: Decodable, Sendable {
    let title: String
    let year: Int?
    let ids: TraktIDs
    let airedEpisodes: Int?

    enum CodingKeys: String, CodingKey {
        case title, year, ids
        case airedEpisodes = "aired_episodes"
    }

    func media(type: String) -> MediaItem? {
        guard let lookup = ids.lookup else { return nil }
        let id = lookup.type == "imdb" ? lookup.value : "\(lookup.type):\(lookup.value)"
        var item = MediaItem(id: id, type: type, name: title)
        item.imdbID = ids.imdb
        item.tmdbID = ids.tmdb
        item.releaseInfo = year.map(String.init)
        return item
    }
}

struct TraktWatchedMovie: Decodable {
    let movie: TraktTitle
    let lastWatchedAt: String
    enum CodingKeys: String, CodingKey { case movie; case lastWatchedAt = "last_watched_at" }
}

struct TraktWatchedShow: Decodable {
    struct Season: Decodable {
        struct Episode: Decodable {
            let number: Int
            let lastWatchedAt: String
            enum CodingKeys: String, CodingKey { case number; case lastWatchedAt = "last_watched_at" }
        }
        let number: Int
        let episodes: [Episode]
    }
    let show: TraktTitle
    let lastWatchedAt: String
    let seasons: [Season]
    enum CodingKeys: String, CodingKey { case show, seasons; case lastWatchedAt = "last_watched_at" }
}

public struct TraktWatchedEntry: Sendable {
    public let media: MediaItem
    public let videoID: String?
    public let watchedAt: Date

    public init(media: MediaItem, videoID: String? = nil, watchedAt: Date) {
        self.media = media
        self.videoID = videoID
        self.watchedAt = watchedAt
    }
}

public struct TraktHistoryChange: Codable, Identifiable, Sendable {
    public enum Action: String, Codable, Sendable {
        case watched, unwatched
        #if !VESPER_GO
        case stopped
        #endif
    }
    public let id: UUID
    public let media: MediaItem
    public let videoID: String?
    public let action: Action
    public let date: Date
    #if !VESPER_GO
    public private(set) var progress: Double? = nil
    #endif

    public init(
        id: UUID = UUID(), media: MediaItem, videoID: String? = nil, action: Action,
        date: Date = Date()
    ) {
        self.id = id
        var compact = media
        compact.videos = nil
        compact.description = nil
        compact.cast = nil
        compact.director = nil
        self.media = compact
        self.videoID = videoID
        self.action = action
        self.date = date
    }

    #if !VESPER_GO
    public init(
        id: UUID = UUID(), media: MediaItem, videoID: String? = nil, action: Action,
        date: Date = Date(), progress: Double?
    ) {
        self.init(id: id, media: media, videoID: videoID, action: action, date: date)
        self.progress = progress
    }
    #endif

    public var watched: Bool { action != .unwatched }
}

#if !VESPER_GO
public enum TraktScrobbleAction: String, Sendable { case start, pause, stop }
#endif

public enum TraktError: Error, LocalizedError, Equatable {
    case notConnected, reconnect, invalidResponse, unidentifiedTitle, authorizationExpired, denied
    case accountLimit, historyLimitReached, rateLimited(TimeInterval), http(Int)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Connect your Trakt account first."
        case .reconnect: "Your Trakt authorization expired. Connect again to resume syncing."
        case .invalidResponse: "Trakt returned an unexpected response. Try again later."
        case .unidentifiedTitle: "This title couldn’t be matched to Trakt using its IDs."
        case .authorizationExpired: "This sign-in code expired. Start again to get a new code."
        case .denied: "Trakt sign-in was declined."
        case .accountLimit:
            "Your Trakt account limit was reached. Review your connected apps or account limits on Trakt."
        case .historyLimitReached: "Your Trakt watch history is too large to sync in one pass."
        case .rateLimited: "Trakt is temporarily limiting requests. Sync will try again later."
        case .http(let status): "Trakt is unavailable (\(status)). Try again later."
        }
    }
}

enum TraktDates {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func string(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
}
