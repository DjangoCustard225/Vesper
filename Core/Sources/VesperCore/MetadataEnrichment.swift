import Foundation

public enum MetadataProvider: String, Codable, Hashable, Sendable { case tmdb, tvdb }

public struct MetadataReference: Codable, Hashable, Sendable {
    public let provider: MetadataProvider
    public let id: Int
    public var key: String { provider.rawValue + ":" + String(id) }
}

public struct CastMember: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let character: String?
    public let portraitURL: String?

    public var provider: MetadataProvider? = nil
    public var linkedTMDBID: Int? = nil
    public var reference: MetadataReference { MetadataReference(provider: provider ?? .tmdb, id: id) }
    public var tmdbID: Int? { provider == .tvdb ? linkedTMDBID : id }
    public var website: URL {
        URL(
            string: provider == .tvdb
                ? "https://thetvdb.com/people/\(id)"
                : "https://www.themoviedb.org/person/\(id)")!
    }
}

public struct CrewMember: Codable, Hashable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let jobs: [String]
    public let portraitURL: String?

    public var provider: MetadataProvider? = nil
    public var linkedTMDBID: Int? = nil
    public var reference: MetadataReference { MetadataReference(provider: provider ?? .tmdb, id: id) }
    public var tmdbID: Int? { provider == .tvdb ? linkedTMDBID : id }
    public var website: URL {
        URL(
            string: provider == .tvdb
                ? "https://thetvdb.com/people/\(id)"
                : "https://www.themoviedb.org/person/\(id)")!
    }
}

public struct MetadataEnrichment: Codable, Hashable, Sendable {
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

    public var provider: MetadataProvider? = nil
    public var linkedTMDBID: Int? = nil
    public var reference: MetadataReference { MetadataReference(provider: provider ?? .tmdb, id: id) }
    public var tmdbID: Int? { provider == .tvdb ? linkedTMDBID : id }
    public var tvdbID: Int? { provider == .tvdb ? id : nil }
    public var website: URL {
        URL(
            string: provider == .tvdb
                ? "https://thetvdb.com/dereferrer/series/\(id)"
                : "https://www.themoviedb.org/\(mediaType)/\(id)")!
    }

    public func applying(to item: MediaItem) -> MediaItem {
        var enriched = item
        if let imdbID { enriched.imdbID = imdbID }
        if let tmdbID { enriched.tmdbID = tmdbID }
        if let tvdbID { enriched.tvdbID = tvdbID }
        if provider != .tvdb { enriched.tmdbRating = rating }
        if let overview, !overview.isEmpty { enriched.description = overview }
        if let posterURL { enriched.poster = posterURL }
        if let backdropURL { enriched.background = backdropURL }
        if let releaseYear, item.type == "movie" || item.releaseInfo?.isEmpty != false {
            enriched.releaseInfo = releaseYear
        }
        if let runtimeMinutes, runtimeMinutes > 0 { enriched.runtime = "\(runtimeMinutes) min" }
        if !genres.isEmpty { enriched.genres = genres }
        if !cast.isEmpty { enriched.cast = cast.map(\.name) }
        if !directors.isEmpty { enriched.director = directors }
        // Preserve the add-on's ID, type, episode list, default video ID and IMDb rating.
        return enriched
    }
}

extension MetadataEnrichment {
    public func fillingMissing(from fallback: MetadataEnrichment?) -> MetadataEnrichment {
        guard let fallback else { return self }
        return MetadataEnrichment(
            id: id, mediaType: mediaType, overview: overview ?? fallback.overview,
            tagline: tagline ?? fallback.tagline, posterURL: posterURL ?? fallback.posterURL,
            backdropURL: backdropURL ?? fallback.backdropURL,
            titleLogoURL: titleLogoURL ?? fallback.titleLogoURL,
            releaseYear: releaseYear ?? fallback.releaseYear,
            runtimeMinutes: runtimeMinutes ?? fallback.runtimeMinutes,
            genres: genres.isEmpty ? fallback.genres : genres, cast: cast.isEmpty ? fallback.cast : cast,
            directors: directors.isEmpty ? fallback.directors : directors,
            directorPeople: directorPeople.isEmpty ? fallback.directorPeople : directorPeople,
            crew: crew?.isEmpty == false ? crew : fallback.crew,
            creators: creators.isEmpty ? fallback.creators : creators, rating: rating, voteCount: voteCount,
            imdbID: imdbID ?? fallback.imdbID, seasons: seasons.isEmpty ? fallback.seasons : seasons,
            provider: provider, linkedTMDBID: tmdbID ?? fallback.tmdbID)
    }
}

public enum MetadataResolver {
    private struct EpisodePosition: Hashable {
        let season: Int
        let number: Int
    }

    public static func episodes(_ primary: [Episode], fillingFrom fallback: [Episode]) -> [Episode] {
        var backups: [EpisodePosition: Episode] = [:]
        for item in fallback {
            guard let season = item.season, let number = item.episode else { continue }
            let key = EpisodePosition(season: season, number: number)
            if backups[key] == nil { backups[key] = item }
        }
        return primary.map { item in
            guard let season = item.season, let number = item.episode,
                let backup = backups[EpisodePosition(season: season, number: number)]
            else { return item }
            return Episode(
                id: item.id, title: item.title ?? backup.title, name: item.name ?? backup.name,
                season: season, episode: number, overview: item.overview ?? backup.overview,
                thumbnail: item.thumbnail ?? backup.thumbnail, released: item.released ?? backup.released,
                streams: item.streams, runtimeMinutes: item.runtimeMinutes ?? backup.runtimeMinutes)
        }
    }

    public static func enrichment(
        isolation: isolated (any Actor)? = #isolation,
        primary: () async throws -> MetadataEnrichment?,
        fallback: () async throws -> MetadataEnrichment?
    ) async throws -> MetadataEnrichment? {
        let result: MetadataEnrichment?
        do { result = try await primary() } catch is CancellationError { throw CancellationError() } catch {
            if let value = try await fallback() { return value }
            throw error
        }
        try Task.checkCancellation()
        // A supplementary provider failure must not discard working TVDB details.
        do {
            let backup = try await fallback()
            return result?.fillingMissing(from: backup) ?? backup
        } catch is CancellationError { throw CancellationError() } catch {
            if let result { return result }; throw error
        }
    }
}
