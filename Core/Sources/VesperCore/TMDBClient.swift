import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

enum TMDBAuthentication: Equatable {
    case apiKey(String), bearer(String)
    init(_ input: String) throws {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (20...4096).contains(value.count), value.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._").contains($0)
        }) else { throw TMDBError.invalidCredential }
        if value.count == 32 && value.allSatisfy(\.isHexDigit) { self = .apiKey(value) }
        else { self = .bearer(value) }
    }
    var value: String { switch self { case .apiKey(let value), .bearer(let value): value } }
}

struct TMDBConfiguration: Codable, Sendable {
    struct Images: Codable, Sendable {
        let secureBaseUrl: String
        let profileSizes: [String]
        let posterSizes: [String]
        let backdropSizes: [String]
        let stillSizes: [String]?
        let logoSizes: [String]?
    }
    let images: Images
    func episodeImage(_ path: String?) -> String? {
        let sizes = images.stillSizes ?? images.backdropSizes
        let largest = sizes.compactMap { size -> (name: String, width: Int)? in
            guard size.hasPrefix("w"), let width = Int(size.dropFirst()), width > 0 else { return nil }
            return (size, width)
        }.max { $0.width < $1.width }
        guard let preferred = sizes.contains("original") ? "original" : largest?.name else { return nil }
        return image(path, sizes: sizes, preferred: preferred)
    }
    func image(_ path: String?, sizes: [String], preferred: String) -> String? {
        guard let path, path.hasPrefix("/"), !path.contains(".."), !path.contains("?"), !path.contains("#"),
              let base = URL(string: images.secureBaseUrl), base.scheme == "https", base.host == "image.tmdb.org",
              let size = sizes.contains(preferred) ? preferred : sizes.first,
              size.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return base.appendingPathComponent(size).appendingPathComponent(String(path.dropFirst())).absoluteString
    }
}

struct TMDBFindResponse: Decodable {
    struct Match: Decodable { let id: Int }
    let movieResults: [Match]?
    let tvResults: [Match]?
}

struct TMDBDetails: Decodable {
    struct Images: Decodable {
        struct Logo: Decodable {
            let filePath: String?
            let iso6391: String?
            let width: Int?
            let voteAverage: Double?
        }
        let logos: [Logo]?
    }
    struct ExternalIDs: Decodable { let imdbId: String? }
    struct Season: Decodable { let seasonNumber: Int; let episodeCount: Int? }
    struct Genre: Decodable { let name: String }
    struct Person: Decodable {
        struct Role: Decodable { let character: String? }
        struct Job: Decodable { let job: String? }
        let id: Int
        let name: String
        let character: String?
        let roles: [Role]?
        let profilePath: String?
        let job: String?
        let jobs: [Job]?
        var isDirector: Bool { job == "Director" || jobs?.contains(where: { $0.job == "Director" }) == true }
    }
    struct Credits: Decodable { let cast: [Person]?; let crew: [Person]? }
    let id: Int
    let overview: String?
    let tagline: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let genres: [Genre]?
    let credits: Credits?
    let aggregateCredits: Credits?
    let createdBy: [Person]?
    let voteAverage: Double?
    let voteCount: Int?
    let externalIds: ExternalIDs?
    let seasons: [Season]?
    let images: Images?

    func enrichment(type: String, configuration: TMDBConfiguration) -> TMDBEnrichment {
        let credits = type == "tv" ? aggregateCredits : credits
        var seen = Set<Int>()
        let cast = (credits?.cast ?? []).filter { !$0.name.isEmpty && seen.insert($0.id).inserted }.prefix(40).map { person in
            var rolesSeen = Set<String>()
            let roles = (person.roles ?? []).compactMap(\.character).filter { !$0.isEmpty && rolesSeen.insert($0).inserted }
            let character = person.character?.isEmpty == false ? person.character : roles.isEmpty ? nil : roles.joined(separator: ", ")
            return CastMember(id: person.id, name: person.name, character: character,
                portraitURL: configuration.image(person.profilePath, sizes: configuration.images.profileSizes, preferred: "w185"))
        }
        var directorIDs = Set<Int>()
        let directorPeople = (credits?.crew ?? []).filter {
            $0.isDirector && $0.id > 0 && !$0.name.isEmpty && directorIDs.insert($0.id).inserted
        }.map { person in
            CastMember(id: person.id, name: person.name, character: nil,
                portraitURL: configuration.image(person.profilePath, sizes: configuration.images.profileSizes, preferred: "w185"))
        }
        // Merge repeated movie credits and aggregate TV jobs into one portrait per person.
        var crewOrder: [Int] = []
        var crewByID: [Int: CrewMember] = [:]
        func addCrew(_ person: Person, jobs: [String]) {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard person.id > 0, !name.isEmpty else { return }
            let previous = crewByID[person.id]
            var seenJobs = Set<String>()
            let roles = ((previous?.jobs ?? []) + jobs).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seenJobs.insert($0).inserted }
            if previous == nil { crewOrder.append(person.id) }
            crewByID[person.id] = CrewMember(id: person.id, name: previous?.name ?? name, jobs: roles,
                portraitURL: previous?.portraitURL ?? configuration.image(person.profilePath, sizes: configuration.images.profileSizes, preferred: "w185"))
        }
        for person in credits?.crew ?? [] {
            addCrew(person, jobs: [person.job].compactMap { $0 } + (person.jobs ?? []).compactMap(\.job))
        }
        for person in createdBy ?? [] { addCrew(person, jobs: ["Creator"]) }
        let crew = crewOrder.compactMap { crewByID[$0] }.enumerated().sorted {
            let first = $0.element.jobs.contains("Director"), second = $1.element.jobs.contains("Director")
            return first != second ? first : $0.offset < $1.offset
        }.prefix(60).map(\.element)
        let logos = (images?.logos ?? []).filter {
            ($0.iso6391 == "en" || $0.iso6391 == nil) &&
            ($0.filePath?.lowercased().hasSuffix(".png") == true || $0.filePath?.lowercased().hasSuffix(".webp") == true)
        }.sorted {
            if ($0.iso6391 == "en") != ($1.iso6391 == "en") { return $0.iso6391 == "en" }
            if ($0.voteAverage ?? 0) != ($1.voteAverage ?? 0) { return ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
            return ($0.width ?? 0) > ($1.width ?? 0)
        }
        let titleLogoURL = logos.lazy.compactMap {
            configuration.image($0.filePath, sizes: configuration.images.logoSizes ?? configuration.images.posterSizes, preferred: "w500")
        }.first
        let date = type == "tv" ? firstAirDate : releaseDate
        let year = date.flatMap { value -> String? in
            let prefix = String(value.prefix(4)); return prefix.count == 4 && Int(prefix) != nil ? prefix : nil
        }
        return TMDBEnrichment(id: id, mediaType: type, overview: overview, tagline: tagline,
            posterURL: configuration.image(posterPath, sizes: configuration.images.posterSizes, preferred: "w500"),
            backdropURL: configuration.image(backdropPath, sizes: configuration.images.backdropSizes, preferred: "w1280"),
            titleLogoURL: titleLogoURL,
            releaseYear: year, runtimeMinutes: runtime ?? episodeRunTime?.first(where: { $0 > 0 }),
            genres: genres?.map(\.name) ?? [], cast: cast,
            directors: Array(Set(directorPeople.map(\.name))).sorted(), directorPeople: directorPeople,
            crew: crew,
            creators: createdBy?.map(\.name) ?? [], rating: (voteCount ?? 0) > 0 ? voteAverage : nil, voteCount: voteCount,
            imdbID: externalIds?.imdbId.flatMap { $0.range(of: "^tt[0-9]+$", options: .regularExpression) != nil ? $0 : nil },
            seasons: Array(Set((seasons ?? []).filter { $0.seasonNumber >= 0 && ($0.episodeCount ?? 1) > 0 }.map(\.seasonNumber))).sorted())
    }
}

final class TMDBRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // Never forward an API key or Authorization header through a redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor TMDBClient {
    private let session: URLSession
    private let transport: HTTPTransport
    private let diskCache: ResponseCache?
    private var activeCredential: String?
    private var configuration: TMDBConfiguration?
    private var configurationRequest: (id: UUID, task: Task<TMDBConfiguration, Error>)?
    private var cache: [String: (Date, TMDBEnrichment)] = [:]
    private var requests: [String: (id: UUID, task: Task<Data?, Error>)] = [:]
    private var listingCache: [String: (Date, TMDBPage)] = [:]
    private var seasonCache: [String: (Date, TMDBSeasonResponse)] = [:]
    public init(session: URLSession? = nil, cache: ResponseCache? = nil, retryPolicy: RetryPolicy = RetryPolicy()) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil; config.httpCookieStorage = nil
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: config, delegate: TMDBRedirectGuard(), delegateQueue: nil)
        }
        diskCache = cache
        transport = HTTPTransport(session: self.session, policy: retryPolicy)
    }
    deinit { session.invalidateAndCancel() }

    public nonisolated static func normalizedCredential(_ input: String) throws -> String { try TMDBAuthentication(input).value }

    static func request(path: [String], query: [URLQueryItem] = [], credential: String) throws -> URLRequest {
        let auth = try TMDBAuthentication(credential)
        var components = URLComponents(string: "https://api.themoviedb.org/3")!
        components.percentEncodedPath += "/" + path.map(AddonURL.encode).joined(separator: "/")
        var parameters = query
        if case .apiKey(let key) = auth { parameters.append(URLQueryItem(name: "api_key", value: key)) }
        if !parameters.isEmpty {
            components.percentEncodedQuery = parameters.map { AddonURL.encode($0.name) + "=" + AddonURL.encode($0.value ?? "") }.joined(separator: "&")
        }
        guard let url = components.url else { throw TMDBError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .bearer(let token) = auth { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func fetch<T: Decodable>(_ type: T.Type, path: [String], query: [URLQueryItem] = [], credential: String) async throws -> T? {
        do {
            let request = try Self.request(path: path, query: query, credential: credential)
            let key = credential + ":" + request.url!.absoluteString
            let pending: (id: UUID, task: Task<Data?, Error>)
            if let existing = requests[key] { pending = existing }
            else {
                let transport = transport
                pending = (UUID(), Task {
                    let (data, response) = try await transport.data(for: request, operation: .tmdb)
                    try Task.checkCancellation()
                    switch response.statusCode {
                    case 200..<300: break
                    case 401, 403: throw TMDBError.unauthorized
                    case 404: return nil
                    case 429: throw TMDBError.rateLimited
                    default: throw TMDBError.http(response.statusCode)
                    }
                    guard data.count < 8_000_000 else { throw TMDBError.invalidResponse }
                    return data
                })
                requests[key] = pending
            }
            defer { if requests[key]?.id == pending.id { requests[key] = nil } }
            let data = try await pending.task.value
            try Task.checkCancellation()
            guard let data else { return nil }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let result = try? decoder.decode(type, from: data) else { throw TMDBError.invalidResponse }
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as TMDBError { throw error }
        catch { throw TMDBError.unavailable }
    }
    private func use(_ credential: String) {
        if activeCredential != credential {
            configurationRequest?.task.cancel(); configurationRequest = nil
            for request in requests.values { request.task.cancel() }
            requests = [:]; listingCache = [:]; seasonCache = [:]
            configuration = nil; cache = [:]; activeCredential = credential
        }
    }
    public func invalidate() async {
        configurationRequest?.task.cancel(); configurationRequest = nil
        for request in requests.values { request.task.cancel() }
        requests = [:]; cache = [:]; listingCache = [:]; seasonCache = [:]; configuration = nil
        activeCredential = nil
        await diskCache?.clear()
    }
    public func identified(_ item: MediaItem, credential input: String, resolveUnknown: Bool = true) async throws -> MediaItem {
        guard ["movie", "series"].contains(item.type) else { return item }
        let credential = try Self.normalizedCredential(input)
        use(credential)
        var result = item
        if let tmdb = MediaIdentity.tmdbID(item) {
            if let diskCache, let cached = await diskCache.value(String.self, key: credential + ":tmdbIdentity:" + item.type + ":" + String(tmdb), ttl: 6 * 3600),
               let imdb = MediaIdentity.validIMDb(cached.value) {
                result.imdbID = MediaIdentity.validIMDb(item.imdbID) ?? imdb
            }
            return result
        }
        guard let imdb = MediaIdentity.validIMDb(item.imdbID) ?? MediaIdentity.validIMDb(item.id) else { return item }
        let key = credential + ":identity:" + item.type + ":" + imdb
        if let diskCache, let cached = await diskCache.value(Int.self, key: key, ttl: 6 * 3600), cached.value > 0 {
            result.tmdbID = cached.value; result.imdbID = imdb; return result
        }
        guard resolveUnknown else { return item }
        let token = await diskCache?.token()
        guard let match = try await fetch(TMDBFindResponse.self, path: ["find", imdb],
            query: [URLQueryItem(name: "external_source", value: "imdb_id")], credential: credential),
              let id = (item.type == "movie" ? match.movieResults : match.tvResults)?.first?.id, id > 0 else { return item }
        try Task.checkCancellation()
        guard activeCredential == credential else { throw CancellationError() }
        result.tmdbID = id; result.imdbID = imdb
        await diskCache?.save(id, key: key, token: token)
        await diskCache?.save(imdb, key: credential + ":tmdbIdentity:" + item.type + ":" + String(id), token: token)
        return result
    }
    public func validate(credential input: String) async throws {
        let credential = try Self.normalizedCredential(input)
        guard let config = try await fetch(TMDBConfiguration.self, path: ["configuration"], credential: credential),
              config.image("/test.jpg", sizes: config.images.profileSizes, preferred: "w185") != nil else { throw TMDBError.invalidResponse }
        use(credential); configuration = config
    }
    public func enrichment(for item: MediaItem, credential input: String, refresh: Bool = false) async throws -> TMDBEnrichment? {
        guard item.type == "movie" || item.type == "series" else { return nil }
        let type = item.type == "movie" ? "movie" : "tv"
        let credential = try Self.normalizedCredential(input)
        try Task.checkCancellation()
        if refresh, let activeCredential, activeCredential != credential { throw CancellationError() }
        use(credential)
        let diskKey = MetadataCacheKey.details(item, credential: credential)
        if !refresh, let (date, value) = cache[item.key], Date().timeIntervalSince(date) < 6 * 3600 { return value }
        if !refresh, let diskCache, let cached = await diskCache.value(TMDBEnrichment.self, key: diskKey, ttl: 6 * 3600) {
            if !cached.isFresh {
                await diskCache.refresh(key: diskKey) { [self] in _ = try await self.enrichment(for: item, credential: credential, refresh: true) }
            }
            try Task.checkCancellation()
            return cached.value
        }
        let token = await diskCache?.token()
        let id: Int
        if let mapped = MediaIdentity.tmdbID(item) { id = mapped }
        else if let imdb = MediaIdentity.validIMDb(item.id) ?? MediaIdentity.validIMDb(item.imdbID) {
            guard let match = try await fetch(TMDBFindResponse.self, path: ["find", imdb],
                query: [URLQueryItem(name: "external_source", value: "imdb_id")], credential: credential),
                  let found = (type == "movie" ? match.movieResults : match.tvResults)?.first, found.id > 0 else { return nil }
            id = found.id
        } else { return nil }
        async let configuration = imageConfiguration(credential: credential)
        guard let details = try await fetch(TMDBDetails.self, path: [type, String(id)],
            query: [URLQueryItem(name: "append_to_response", value: type == "movie" ? "credits,external_ids,images" : "aggregate_credits,external_ids,images"),
                    URLQueryItem(name: "language", value: "en-US"),
                    URLQueryItem(name: "include_image_language", value: "en,null")], credential: credential), details.id == id else { return nil }
        let value = try await details.enrichment(type: type, configuration: configuration)
        if activeCredential == credential {
            cache = cache.filter { Date().timeIntervalSince($0.value.0) < 6 * 3600 }
            if cache.count >= 100, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache.removeValue(forKey: oldest) }
            cache[item.key] = (Date(), value)
            await diskCache?.save(value, key: diskKey, token: token)
            if let imdb = value.imdbID {
                await diskCache?.save(id, key: credential + ":identity:" + item.type + ":" + imdb, token: token)
                await diskCache?.save(imdb, key: credential + ":tmdbIdentity:" + item.type + ":" + String(id), token: token)
            }
        }
        return value
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

private struct TMDBListing: Decodable {
    struct Entry: Decodable {
        let id: Int
        let mediaType: String?
        let title: String?
        let name: String?
        let overview: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let firstAirDate: String?
        let voteAverage: Double?
        let voteCount: Int?
        let adult: Bool?
        func item(type: String, configuration: TMDBConfiguration) -> MediaItem? {
            guard id > 0, adult != true, type == "movie" || type == "tv",
                  let name = type == "movie" ? title : name, !name.isEmpty else { return nil }
            return MediaItem(id: "tmdb:\(type):\(id)", type: type == "tv" ? "series" : "movie", name: name,
                poster: configuration.image(posterPath, sizes: configuration.images.posterSizes, preferred: "w500"),
                background: configuration.image(backdropPath, sizes: configuration.images.backdropSizes, preferred: "w1280"),
                description: overview, releaseInfo: (type == "tv" ? firstAirDate : releaseDate).flatMap { $0.isEmpty ? nil : String($0.prefix(4)) },
                tmdbRating: (voteCount ?? 0) > 0 ? voteAverage : nil)
        }
    }
    let page: Int
    let totalPages: Int
    let results: [Entry]
}

private struct TMDBSeasonResponse: Decodable, Sendable {
    struct Video: Decodable, Sendable {
        let name: String?
        let seasonNumber: Int
        let episodeNumber: Int
        let overview: String?
        let stillPath: String?
        let airDate: String?
        let runtime: Int?
    }
    let seasonNumber: Int
    let episodes: [Video]
}

extension TMDBClient {
    private func imageConfiguration(credential: String) async throws -> TMDBConfiguration {
        if let configuration { return configuration }
        if let diskCache, let cached = await diskCache.value(TMDBConfiguration.self, key: credential + ":configuration", ttl: 7 * 24 * 3600) {
            guard activeCredential == credential else { throw CancellationError() }
            configuration = cached.value
            return cached.value
        }
        if let request = configurationRequest {
            let value = try await request.task.value
            try Task.checkCancellation()
            guard activeCredential == credential else { throw CancellationError() }
            return value
        }
        let id = UUID()
        let token = await diskCache?.token()
        let task = Task<TMDBConfiguration, Error> {
            guard let value = try await fetch(TMDBConfiguration.self, path: ["configuration"], credential: credential) else { throw TMDBError.invalidResponse }
            return value
        }
        configurationRequest = (id, task)
        do {
            let value = try await task.value
            guard activeCredential == credential else { throw CancellationError() }
            configuration = value
            await diskCache?.save(value, key: credential + ":configuration", token: token)
            if configurationRequest?.id == id { configurationRequest = nil }
            try Task.checkCancellation()
            return value
        } catch {
            if configurationRequest?.id == id { configurationRequest = nil }
            throw error
        }
    }
    public func catalog(_ catalog: TMDBCatalog, page: Int = 1, credential input: String) async throws -> TMDBPage {
        try await listing(path: catalog.path, type: catalog.mediaType, page: page, credential: input)
    }
    public func search(_ term: String, page: Int = 1, credential input: String) async throws -> TMDBPage {
        try await listing(path: ["search", "multi"], type: nil, page: page,
            query: [URLQueryItem(name: "query", value: term), URLQueryItem(name: "include_adult", value: "false")], credential: input)
    }
    public func recommendations(tmdbID: Int, mediaType: String, page: Int = 1, credential input: String) async throws -> TMDBPage {
        guard tmdbID > 0, mediaType == "movie" || mediaType == "tv" else { throw TMDBError.invalidResponse }
        let result = try await listing(path: [mediaType, String(tmdbID), "recommendations"], type: mediaType,
                                       page: page, credential: input)
        let currentID = "tmdb:\(mediaType):\(tmdbID)"
        return TMDBPage(items: result.items.filter { $0.id != currentID && $0.poster != nil }, page: result.page, totalPages: result.totalPages)
    }
    private func listing(path: [String], type: String?, page: Int, query: [URLQueryItem] = [], credential input: String, refresh: Bool = false) async throws -> TMDBPage {
        guard (1...500).contains(page) else { throw TMDBError.invalidResponse }
        let credential = try Self.normalizedCredential(input)
        try Task.checkCancellation()
        if refresh, let activeCredential, activeCredential != credential { throw CancellationError() }
        use(credential)
        let parameters = query + [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "language", value: "en-US")]
        let cacheKey = try Self.request(path: path, query: parameters, credential: credential).url!.absoluteString
        // Search keeps only the short-lived memory cache used in 0.1. Persisted
        // result pages must not replace a fresh query after an app update/restart.
        let listingDiskCache = path.first == "search" ? nil : diskCache
        if !refresh, let (date, value) = listingCache[cacheKey], Date().timeIntervalSince(date) < 300 { return value }
        let diskKey = try MetadataCacheKey.listing(credential: credential, path: path, page: page, query: query)
        if !refresh, let diskCache = listingDiskCache, let cached = await diskCache.value(TMDBPage.self, key: diskKey, ttl: 300) {
            if !cached.isFresh {
                await diskCache.refresh(key: diskKey) { [self] in _ = try await self.listing(path: path, type: type, page: page, query: query, credential: credential, refresh: true) }
            }
            try Task.checkCancellation()
            return cached.value
        }
        let token = await listingDiskCache?.token()
        async let configuration = imageConfiguration(credential: credential)
        guard let result = try await fetch(TMDBListing.self, path: path,
            query: parameters, credential: credential),
              result.page == page, result.totalPages >= 0 else { throw TMDBError.invalidResponse }
        let config = try await configuration
        guard activeCredential == credential else { throw CancellationError() }
        var seen = Set<String>()
        let items = result.results.compactMap { $0.item(type: type ?? $0.mediaType ?? "", configuration: config) }.filter { seen.insert($0.key).inserted }
        let value = TMDBPage(items: items, page: result.page, totalPages: min(result.totalPages, 500))
        listingCache = listingCache.filter { Date().timeIntervalSince($0.value.0) < 300 }
        if listingCache.count >= 100, let oldest = listingCache.min(by: { $0.value.0 < $1.value.0 })?.key { listingCache[oldest] = nil }
        listingCache[cacheKey] = (Date(), value)
        await listingDiskCache?.save(value, key: diskKey, token: token)
        return value
    }
    public func episodes(for media: MediaItem, tmdbID: Int, season: Int, credential input: String, refresh: Bool = false) async throws -> [Episode] {
        guard media.type == "series", tmdbID > 0, season >= 0 else { throw TMDBError.invalidResponse }
        let credential = try Self.normalizedCredential(input)
        try Task.checkCancellation()
        if refresh, let activeCredential, activeCredential != credential { throw CancellationError() }
        use(credential)
        let cacheKey = "\(tmdbID):\(season)"
        let diskKey = MetadataCacheKey.episodes(media, id: tmdbID, season: season, credential: credential)
        if !refresh, let diskCache, let cached = await diskCache.value([Episode].self, key: diskKey, ttl: 6 * 3600) {
            if !cached.isFresh {
                await diskCache.refresh(key: diskKey) { [self] in _ = try await self.episodes(for: media, tmdbID: tmdbID, season: season, credential: credential, refresh: true) }
            }
            try Task.checkCancellation()
            return cached.value
        }
        let token = await diskCache?.token()
        async let configuration = imageConfiguration(credential: credential)
        let result: TMDBSeasonResponse
        let cached = refresh ? nil : seasonCache[cacheKey].flatMap { Date().timeIntervalSince($0.0) < 6 * 3600 ? $0.1 : nil }
        if let cached { result = cached }
        else {
            guard let value = try await fetch(TMDBSeasonResponse.self, path: ["tv", String(tmdbID), "season", String(season)],
                query: [URLQueryItem(name: "language", value: "en-US")], credential: credential), value.seasonNumber == season else { throw TMDBError.invalidResponse }
            result = value
        }
        let config = try await configuration
        guard activeCredential == credential else { throw CancellationError() }
        if cached == nil {
            seasonCache = seasonCache.filter { Date().timeIntervalSince($0.value.0) < 6 * 3600 }
            if seasonCache.count >= 50, let oldest = seasonCache.min(by: { $0.value.0 < $1.value.0 })?.key { seasonCache[oldest] = nil }
            seasonCache[cacheKey] = (Date(), result)
        }
        var seen = Set<Int>()
        let episodes = result.episodes.filter { $0.seasonNumber == season && $0.episodeNumber > 0 && seen.insert($0.episodeNumber).inserted }.map {
            Episode(id: "\(media.playbackID):\(season):\($0.episodeNumber)", title: $0.name, name: nil, season: season,
                episode: $0.episodeNumber, overview: $0.overview,
                thumbnail: config.episodeImage($0.stillPath),
                released: $0.airDate, streams: nil, runtimeMinutes: $0.runtime.flatMap { $0 > 0 ? $0 : nil })
        }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
        await diskCache?.save(episodes, key: diskKey, token: token)
        return episodes
    }
}
