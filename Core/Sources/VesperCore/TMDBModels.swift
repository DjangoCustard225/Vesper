import Foundation

public enum TMDBError: LocalizedError, Equatable {
    case invalidCredential, unauthorized, rateLimited, unavailable, invalidResponse, http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: "Enter your TMDB API key or API Read Access Token."
        case .unauthorized:
            "TMDB rejected this credential. Check your API key or read access token in Settings."
        case .rateLimited: "TMDB is temporarily limiting requests. Try again shortly."
        case .unavailable: "TMDB couldn’t be reached. Try again shortly."
        case .invalidResponse: "TMDB returned an unreadable response. Try again shortly."
        case .http(let status): "TMDB returned HTTP \(status). Try again shortly."
        }
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

    var path: [String] {
        [mediaType, self == .popularMovies || self == .popularSeries ? "popular" : "top_rated"]
    }
}

public struct TMDBPage: Codable, Sendable {
    public let items: [MediaItem]
    public let page: Int
    public let totalPages: Int

    public var hasMore: Bool { page < totalPages && page < 500 }
}
