import Foundation

public enum TMDBError: LocalizedError, Equatable {
    case invalidCredential, unauthorized, rateLimited, unavailable, invalidResponse, http(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidCredential: "Enter your TMDB API key or API Read Access Token."
        case .unauthorized: "TMDB rejected this credential. Check your API key or read access token in Settings."
        case .rateLimited: "TMDB is temporarily limiting requests. Try again shortly."
        case .unavailable: "TMDB couldn’t be reached. Try again shortly."
        case .invalidResponse: "TMDB returned an unreadable response. Try again shortly."
        case .http(let status): "TMDB returned HTTP \(status). Try again shortly."
        }
    }
}

public struct CastMember: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let character: String?
    public let portraitURL: String?
    public var website: URL { URL(string: "https://www.themoviedb.org/person/\(id)")! }
}

public struct CrewMember: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let jobs: [String]
    public let portraitURL: String?
    public var website: URL { URL(string: "https://www.themoviedb.org/person/\(id)")! }
}

public struct TMDBEnrichment: Codable, Hashable, Sendable {
    public let id: Int
    public let mediaType: String
    public let overview: String?
    public let tagline: String?
    public let posterURL: String?
    public let backdropURL: String?
    public let titleLogoURL: String?
    public let releaseYear: String?
    public let runtimeMinutes: Int?
    public let genres: [String]
    public let cast: [CastMember]
    public let directors: [String]
    public let directorPeople: [CastMember]
    public let crew: [CrewMember]?
    public let creators: [String]
    public let rating: Double?
    public let voteCount: Int?
    public let imdbID: String?
    public let seasons: [Int]
    public var website: URL { URL(string: "https://www.themoviedb.org/\(mediaType)/\(id)")! }

    public func applying(to item: MediaItem) -> MediaItem {
        var enriched = item
        if let imdbID { enriched.imdbID = imdbID }
        enriched.tmdbID = id
        enriched.tmdbRating = rating
        if let overview, !overview.isEmpty { enriched.description = overview }
        if let posterURL { enriched.poster = posterURL }
        if let backdropURL { enriched.background = backdropURL }
        if let releaseYear, item.type == "movie" || item.releaseInfo?.isEmpty != false { enriched.releaseInfo = releaseYear }
        if let runtimeMinutes, runtimeMinutes > 0 { enriched.runtime = "\(runtimeMinutes) min" }
        if !genres.isEmpty { enriched.genres = genres }
        if !cast.isEmpty { enriched.cast = cast.map(\.name) }
        if !directors.isEmpty { enriched.director = directors }
        // Preserve the add-on's ID, type, episode list, default video ID and IMDb rating.
        return enriched
    }
}

public enum TMDBCatalog: String, CaseIterable, Identifiable, Sendable {
    case popularMovies, popularSeries, topRatedMovies, topRatedSeries
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .popularMovies: "Popular movies"
        case .popularSeries: "Popular series"
        case .topRatedMovies: "Top rated movies"
        case .topRatedSeries: "Top rated series"
        }
    }
    var mediaType: String { self == .popularMovies || self == .topRatedMovies ? "movie" : "tv" }
    var path: [String] { [mediaType, self == .popularMovies || self == .popularSeries ? "popular" : "top_rated"] }
}

public struct TMDBPage: Codable, Sendable {
    public let items: [MediaItem]
    public let page: Int
    public let totalPages: Int
    public var hasMore: Bool { page < totalPages && page < 500 }
}
