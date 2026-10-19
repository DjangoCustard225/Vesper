import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TMDBRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    // Never forward an API key or Authorization header through a redirect.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

public actor TMDBClient {
    private let session: URLSession
    private let ownsSession: Bool
    private let transport: HTTPTransport
    private let diskCache: ResponseCache?
    private var activeCredential: String?
    private var configuration: TMDBConfiguration?
    private var cache = ExpiringCache<MetadataEnrichment>(lifetime: 6 * 3600, capacity: 100)
    private var requests = SharedRequestPool<Data?>()
    private var listingCache = ExpiringCache<TMDBPage>(lifetime: 300, capacity: 100)
    private var seasonCache = ExpiringCache<TMDBSeasonResponse>(lifetime: 6 * 3600, capacity: 50)
    private var personCache = ExpiringCache<PersonFilmography>(lifetime: 6 * 3600, capacity: 50)
    private var genreCache = ExpiringCache<[TMDBGenre]>(lifetime: 7 * 24 * 3600, capacity: 2)

    public init(
        session: URLSession? = nil, cache: ResponseCache? = nil, retryPolicy: RetryPolicy = RetryPolicy()
    ) {
        ownsSession = session == nil
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 25
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(
                configuration: config, delegate: TMDBRedirectGuard(), delegateQueue: nil)
        }
        diskCache = cache
        transport = HTTPTransport(session: self.session, policy: retryPolicy)
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    // MARK: - Request construction and transport

    func requestSubscriberCount(path: [String], query: [URLQueryItem] = [], credential: String) async throws
        -> Int
    {
        let request = try Self.request(path: path, query: query, credential: credential)
        return await requests.subscriberCount(for: credential + ":" + (try Self.urlKey(request)))
    }

    public nonisolated static func normalizedCredential(_ input: String) throws -> String {
        try TMDBAuthentication(input).value
    }

    static func request(path: [String], query: [URLQueryItem] = [], credential: String) throws -> URLRequest {
        let auth = try TMDBAuthentication(credential)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.themoviedb.org"
        components.path = "/3"
        components.percentEncodedPath += "/" + path.map(AddonURL.encode).joined(separator: "/")
        var parameters = query
        if case .apiKey(let key) = auth { parameters.append(URLQueryItem(name: "api_key", value: key)) }
        if !parameters.isEmpty {
            components.percentEncodedQuery = parameters.map {
                AddonURL.encode($0.name) + "=" + AddonURL.encode($0.value ?? "")
            }.joined(separator: "&")
        }
        guard let url = components.url else { throw TMDBError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .bearer(let token) = auth {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func urlKey(_ request: URLRequest) throws -> String {
        guard let url = request.url else { throw TMDBError.invalidResponse }
        return url.absoluteString
    }

    private func fetch<T: Decodable>(
        _ type: T.Type, path: [String], query: [URLQueryItem] = [], credential: String
    ) async throws -> T? {
        do {
            let request = try Self.request(path: path, query: query, credential: credential)
            let key = credential + ":" + (try Self.urlKey(request))
            let transport = transport
            let data = try await requests.value(for: key) {
                let (data, response) = try await transport.data(for: request, operation: .tmdb)
                try Task.checkCancellation()
                switch response.statusCode {
                case 200..<300: break
                case 401, 403: throw TMDBError.unauthorized
                case 404: return nil
                case 429: throw TMDBError.rateLimited
                default: throw TMDBError.http(response.statusCode)
                }
                return data
            }
            try Task.checkCancellation()
            guard let data else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let result = try? decoder.decode(type, from: data) else { throw TMDBError.invalidResponse }
            return result
        } catch is CancellationError { throw CancellationError() } catch let error as URLError
            where error.code == .cancelled
        { throw CancellationError() } catch let error as URLError
            where error.code == .dataLengthExceedsMaximum
        { throw TMDBError.invalidResponse } catch let error as TMDBError { throw error } catch {
            throw TMDBError.unavailable
        }
    }
    // MARK: - Cache lifecycle

    private func use(_ credential: String) {
        guard activeCredential != credential else { return }
        resetMemory()
        activeCredential = credential
    }

    private func resetMemory() {
        let previous = requests
        requests = SharedRequestPool()
        Task { await previous.cancelAll() }
        cache.removeAll()
        listingCache.removeAll()
        seasonCache.removeAll()
        personCache.removeAll()
        genreCache.removeAll()
        configuration = nil
    }

    public func invalidate() async {
        try? await clearCache()
    }

    public func clearCache() async throws {
        resetMemory()
        activeCredential = nil
        session.configuration.urlCache?.removeAllCachedResponses()
        try await diskCache?.removeAll()
    }
    // MARK: - Identity and enriched details

    public func identified(_ item: MediaItem, credential input: String, resolveUnknown: Bool = true)
        async throws -> MediaItem
    {
        guard ["movie", "series"].contains(item.type) else { return item }
        let credential = try Self.normalizedCredential(input)
        use(credential)
        var result = item
        if let tmdb = MediaIdentity.tmdbID(item) {
            if let diskCache,
                let cached = await diskCache.value(
                    String.self, key: credential + ":tmdbIdentity:" + item.type + ":" + String(tmdb),
                    ttl: 6 * 3600),
                let imdb = MediaIdentity.validIMDb(cached.value)
            {
                result.imdbID = MediaIdentity.validIMDb(item.imdbID) ?? imdb
            }
            return result
        }
        guard let imdb = MediaIdentity.validIMDb(item.imdbID) ?? MediaIdentity.validIMDb(item.id) else {
            return item
        }
        let key = credential + ":identity:" + item.type + ":" + imdb
        if let diskCache, let cached = await diskCache.value(Int.self, key: key, ttl: 6 * 3600),
            cached.value > 0
        {
            result.tmdbID = cached.value
            result.imdbID = imdb
            return result
        }
        guard resolveUnknown else { return item }
        let token = await diskCache?.token()
        guard
            let match = try await fetch(
                TMDBFindResponse.self, path: ["find", imdb],
                query: [URLQueryItem(name: "external_source", value: "imdb_id")], credential: credential),
            let id = (item.type == "movie" ? match.movieResults : match.tvResults)?.first?.id, id > 0
        else { return item }
        try Task.checkCancellation()
        guard activeCredential == credential else { throw CancellationError() }
        result.tmdbID = id
        result.imdbID = imdb
        await diskCache?.save(id, key: key, token: token)
        await diskCache?.save(
            imdb, key: credential + ":tmdbIdentity:" + item.type + ":" + String(id), token: token)
        return result
    }

    public func validate(credential input: String) async throws {
        let credential = try Self.normalizedCredential(input)
        guard
            let config = try await fetch(
                TMDBConfiguration.self, path: ["configuration"], credential: credential),
            config.image("/test.jpg", sizes: config.images.profileSizes, preferred: "w185") != nil
        else { throw TMDBError.invalidResponse }
        use(credential)
        configuration = config
    }

    public func enrichment(for item: MediaItem, credential input: String, refresh: Bool = false) async throws
        -> MetadataEnrichment?
    {
        guard item.type == "movie" || item.type == "series" else { return nil }
        let type = item.type == "movie" ? "movie" : "tv"
        let credential = try Self.normalizedCredential(input)
        try Task.checkCancellation()
        if refresh, let activeCredential, activeCredential != credential { throw CancellationError() }
        use(credential)
        let diskKey = MetadataCacheKey.details(item, credential: credential)
        if !refresh, let value = cache.value(for: item.key) { return value }
        if !refresh, let diskCache,
            let cached = await diskCache.value(MetadataEnrichment.self, key: diskKey, ttl: 6 * 3600)
        {
            if !cached.isFresh {
                await diskCache.refresh(key: diskKey) { [self] in
                    _ = try await self.enrichment(for: item, credential: credential, refresh: true)
                }
            }
            try Task.checkCancellation()
            return cached.value
        }
        let token = await diskCache?.token()
        let id: Int
        if let mapped = MediaIdentity.tmdbID(item) {
            id = mapped
        } else if let imdb = MediaIdentity.validIMDb(item.id) ?? MediaIdentity.validIMDb(item.imdbID) {
            guard
                let match = try await fetch(
                    TMDBFindResponse.self, path: ["find", imdb],
                    query: [URLQueryItem(name: "external_source", value: "imdb_id")], credential: credential),
                let found = (type == "movie" ? match.movieResults : match.tvResults)?.first, found.id > 0
            else { return nil }
            id = found.id
        } else {
            return nil
        }
        async let configuration = imageConfiguration(credential: credential)
        guard
            let details = try await fetch(
                TMDBDetails.self, path: [type, String(id)],
                query: [
                    URLQueryItem(
                        name: "append_to_response",
                        value: type == "movie"
                            ? "credits,external_ids,images" : "aggregate_credits,external_ids,images"),
                    URLQueryItem(name: "language", value: "en-US"),
                    URLQueryItem(name: "include_image_language", value: "en,null"),
                ], credential: credential), details.id == id
        else { return nil }
        let value = try await details.enrichment(type: type, configuration: configuration)
        if activeCredential == credential {
            cache.insert(value, for: item.key)
            await diskCache?.save(value, key: diskKey, token: token)
            if let imdb = value.imdbID {
                await diskCache?.save(
                    id, key: credential + ":identity:" + item.type + ":" + imdb, token: token)
                await diskCache?.save(
                    imdb, key: credential + ":tmdbIdentity:" + item.type + ":" + String(id), token: token)
            }
        }
        return value
    }
}

extension TMDBClient {
    // MARK: - People and image configuration

    public func filmography(personID: Int, credential input: String, refresh: Bool = false) async throws
        -> PersonFilmography
    {
        guard personID > 0 else { throw TMDBError.invalidResponse }
        let credential = try Self.normalizedCredential(input)
        try Task.checkCancellation()
        if refresh, let activeCredential, activeCredential != credential { throw CancellationError() }
        use(credential)
        let key = MetadataCacheKey.personFilmography(personID, credential: credential)
        if !refresh, let value = personCache.value(for: key) { return value }
        if !refresh, let diskCache,
            let cached = await diskCache.value(PersonFilmography.self, key: key, ttl: 6 * 3600)
        {
            if !cached.isFresh {
                await diskCache.refresh(key: key) { [self] in
                    _ = try await filmography(personID: personID, credential: credential, refresh: true)
                }
            }
            try Task.checkCancellation()
            guard activeCredential == credential else { throw CancellationError() }
            return cached.value
        }
        let token = await diskCache?.token()
        async let configuration = imageConfiguration(credential: credential)
        async let movieGenres = self.genres(type: "movie", credential: credential)
        async let tvGenres = self.genres(type: "tv", credential: credential)
        guard
            let response = try await fetch(
                TMDBPersonCredits.self, path: ["person", String(personID), "combined_credits"],
                query: [URLQueryItem(name: "language", value: "en-US")], credential: credential),
            response.id == personID
        else {
            throw TMDBError.invalidResponse
        }
        let config = try await configuration
        var genres: [Int: TMDBGenre] = [:]
        for genre in try await movieGenres + tvGenres where genre.id > 0 && !genre.name.isEmpty {
            if genres[genre.id] == nil { genres[genre.id] = genre }
        }
        var credits: [String: PersonCredit] = [:]
        for entry in response.cast {
            guard let media = entry.item(type: entry.mediaType ?? "", configuration: config) else { continue }
            let date = (entry.mediaType == "tv" ? entry.firstAirDate : entry.releaseDate).flatMap {
                $0.isEmpty ? nil : $0
            }
            let previous = credits[media.key]
            let preferred = previous.map { $0.media.poster != nil ? $0.media : media } ?? media
            credits[media.key] = PersonCredit(
                media: preferred,
                genreIDs: Array(Set((previous?.genreIDs ?? []) + (entry.genreIds ?? []))).sorted(),
                popularity: max(previous?.popularity ?? 0, entry.popularity ?? 0),
                releaseDate: previous?.releaseDate ?? date,
                voteCount: max(previous?.voteCount ?? 0, entry.voteCount ?? 0))
        }
        let result = PersonFilmography(
            credits: credits.values.sorted { $0.id < $1.id },
            genres: genres.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        try Task.checkCancellation()
        guard activeCredential == credential else { throw CancellationError() }
        personCache.insert(result, for: key)
        await diskCache?.save(result, key: key, token: token)
        return result
    }

    private func genres(type: String, credential: String) async throws -> [TMDBGenre] {
        let key = credential + ":genres:" + type
        if let value = genreCache.value(for: key) { return value }
        if let diskCache, let cached = await diskCache.value([TMDBGenre].self, key: key, ttl: 7 * 24 * 3600) {
            guard activeCredential == credential else { throw CancellationError() }
            genreCache.insert(cached.value, for: key)
            return cached.value
        }
        let token = await diskCache?.token()
        guard
            let result = try await fetch(
                TMDBGenreList.self, path: ["genre", type, "list"],
                query: [URLQueryItem(name: "language", value: "en-US")], credential: credential)
        else { throw TMDBError.invalidResponse }
        try Task.checkCancellation()
        guard activeCredential == credential else { throw CancellationError() }
        genreCache.insert(result.genres, for: key)
        await diskCache?.save(result.genres, key: key, token: token)
        return result.genres
    }

    private func imageConfiguration(credential: String) async throws -> TMDBConfiguration {
        if let configuration { return configuration }
        if let diskCache,
            let cached = await diskCache.value(
                TMDBConfiguration.self, key: credential + ":configuration", ttl: 7 * 24 * 3600)
        {
            guard activeCredential == credential else { throw CancellationError() }
            configuration = cached.value
            return cached.value
        }
        let token = await diskCache?.token()
        guard
            let value = try await fetch(
                TMDBConfiguration.self, path: ["configuration"], credential: credential)
        else { throw TMDBError.invalidResponse }
        guard activeCredential == credential else { throw CancellationError() }
        configuration = value
        await diskCache?.save(value, key: credential + ":configuration", token: token)
        try Task.checkCancellation()
        return value
    }
    // MARK: - Catalogs and search

    public func catalog(_ catalog: TMDBCatalog, page: Int = 1, credential input: String) async throws
        -> TMDBPage
    {
        try await listing(path: catalog.path, type: catalog.mediaType, page: page, credential: input)
    }

    public func search(_ term: String, page: Int = 1, credential input: String) async throws -> TMDBPage {
        try await listing(
            path: ["search", "multi"], type: nil, page: page,
            query: [
                URLQueryItem(name: "query", value: term), URLQueryItem(name: "include_adult", value: "false"),
            ], credential: input)
    }

    public func recommendations(tmdbID: Int, mediaType: String, page: Int = 1, credential input: String)
        async throws -> TMDBPage
    {
        guard tmdbID > 0, mediaType == "movie" || mediaType == "tv" else { throw TMDBError.invalidResponse }
        let result = try await listing(
            path: [mediaType, String(tmdbID), "recommendations"], type: mediaType,
            page: page, credential: input)
        let currentID = "tmdb:\(mediaType):\(tmdbID)"
        return TMDBPage(
            items: result.items.filter { $0.id != currentID && $0.poster != nil }, page: result.page,
            totalPages: result.totalPages)
    }

    private func listing(
        path: [String], type: String?, page: Int, query: [URLQueryItem] = [], credential input: String,
        refresh: Bool = false
    ) async throws -> TMDBPage {
        guard (1...500).contains(page) else { throw TMDBError.invalidResponse }
        let credential = try Self.normalizedCredential(input)
        try Task.checkCancellation()
        if refresh, let activeCredential, activeCredential != credential { throw CancellationError() }
        use(credential)
        let parameters =
            query + [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "language", value: "en-US"),
            ]
        let cacheKey = try Self.urlKey(Self.request(path: path, query: parameters, credential: credential))
        // Search keeps only the short-lived memory cache used in 0.1. Persisted
        // result pages must not replace a fresh query after an app update/restart.
        let listingDiskCache = path.first == "search" ? nil : diskCache
        if !refresh, let value = listingCache.value(for: cacheKey) { return value }
        let diskKey = try MetadataCacheKey.listing(
            credential: credential, path: path, page: page, query: query)
        if !refresh, let diskCache = listingDiskCache,
            let cached = await diskCache.value(TMDBPage.self, key: diskKey, ttl: 300)
        {
            if !cached.isFresh {
                await diskCache.refresh(key: diskKey) { [self] in
                    _ = try await self.listing(
                        path: path, type: type, page: page, query: query, credential: credential,
                        refresh: true)
                }
            }
            try Task.checkCancellation()
            return cached.value
        }
        let token = await listingDiskCache?.token()
        async let configuration = imageConfiguration(credential: credential)
        guard
            let result = try await fetch(
                TMDBListing.self, path: path,
                query: parameters, credential: credential),
            result.page == page, result.totalPages >= 0
        else { throw TMDBError.invalidResponse }
        let config = try await configuration
        guard activeCredential == credential else { throw CancellationError() }
        var seen = Set<String>()
        let items = result.results.compactMap {
            $0.item(type: type ?? $0.mediaType ?? "", configuration: config)
        }.filter { seen.insert($0.key).inserted }
        let value = TMDBPage(items: items, page: result.page, totalPages: min(result.totalPages, 500))
        listingCache.insert(value, for: cacheKey)
        await listingDiskCache?.save(value, key: diskKey, token: token)
        return value
    }
    // MARK: - Seasons and episodes

    public func episodes(
        for media: MediaItem, tmdbID: Int, season: Int, credential input: String, refresh: Bool = false
    ) async throws -> [Episode] {
        guard media.type == "series", tmdbID > 0, season >= 0 else { throw TMDBError.invalidResponse }
        let credential = try Self.normalizedCredential(input)
        try Task.checkCancellation()
        if refresh, let activeCredential, activeCredential != credential { throw CancellationError() }
        use(credential)
        let cacheKey = "\(tmdbID):\(season)"
        let diskKey = MetadataCacheKey.episodes(media, id: tmdbID, season: season, credential: credential)
        if !refresh, let diskCache,
            let cached = await diskCache.value([Episode].self, key: diskKey, ttl: 6 * 3600)
        {
            if !cached.isFresh {
                await diskCache.refresh(key: diskKey) { [self] in
                    _ = try await self.episodes(
                        for: media, tmdbID: tmdbID, season: season, credential: credential, refresh: true)
                }
            }
            try Task.checkCancellation()
            return cached.value
        }
        let token = await diskCache?.token()
        async let configuration = imageConfiguration(credential: credential)
        let result: TMDBSeasonResponse
        let cached = refresh ? nil : seasonCache.value(for: cacheKey)
        if let cached {
            result = cached
        } else {
            guard
                let value = try await fetch(
                    TMDBSeasonResponse.self, path: ["tv", String(tmdbID), "season", String(season)],
                    query: [URLQueryItem(name: "language", value: "en-US")], credential: credential),
                value.seasonNumber == season
            else { throw TMDBError.invalidResponse }
            result = value
        }
        let config = try await configuration
        guard activeCredential == credential else { throw CancellationError() }
        if cached == nil {
            seasonCache.insert(result, for: cacheKey)
        }
        var seen = Set<Int>()
        let episodes = result.episodes.filter {
            $0.seasonNumber == season && $0.episodeNumber > 0 && seen.insert($0.episodeNumber).inserted
        }.map {
            Episode(
                id: "\(media.playbackID):\(season):\($0.episodeNumber)", title: $0.name, name: nil,
                season: season,
                episode: $0.episodeNumber, overview: $0.overview,
                thumbnail: config.episodeImage($0.stillPath),
                released: $0.airDate, streams: nil, runtimeMinutes: $0.runtime.flatMap { $0 > 0 ? $0 : nil })
        }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
        await diskCache?.save(episodes, key: diskKey, token: token)
        return episodes
    }
}
