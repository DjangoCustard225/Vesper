import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class TVDBRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

public actor TVDBClient {
    private let session: URLSession
    private let ownsSession: Bool
    private let transport: HTTPTransport
    private let disk: ResponseCache?
    private let requests = SharedRequestPool<Data?>()
    private var tokens = ExpiringCache<String>(lifetime: 28 * 24 * 3600, capacity: 1)
    private var memory = ExpiringCache<Data>(lifetime: 6 * 3600, capacity: 150)
    private var generation = UUID()

    public init(
        session: URLSession? = nil, cache: ResponseCache? = nil,
        retryPolicy: RetryPolicy = RetryPolicy()
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
                configuration: config, delegate: TVDBRedirectGuard(), delegateQueue: nil)
        }
        disk = cache
        transport = HTTPTransport(session: self.session, policy: retryPolicy)
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    public func invalidate() async {
        generation = UUID()
        tokens.removeAll()
        memory.removeAll()
        await requests.cancelAll()
        await disk?.cancelRefreshes()
    }

    public func clearCache() async throws {
        await invalidate()
        try await disk?.removeAll()
    }

    public func validate(credentials: TVDBCredentials) async throws {
        _ = try await token(credentials)
    }

    public nonisolated static func detailsKey(_ item: MediaItem, credentials: TVDBCredentials) -> String {
        "tvdb:" + credentials.fingerprint + ":details:" + item.key
    }

    public nonisolated static func episodesKey(id: Int, season: Int, credentials: TVDBCredentials) -> String {
        "tvdb:" + credentials.fingerprint + ":episodes:\(id):\(season)"
    }

    private func token(_ credentials: TVDBCredentials) async throws -> String {
        let key = credentials.fingerprint
        if let token = tokens.value(for: key) { return token }
        let current = generation, transport = transport
        let data = try await requests.value(for: "login:" + key) {
            var request = URLRequest(url: URL(string: "https://api4.thetvdb.com/v4/login")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body = ["apikey": credentials.apiKey]
            if let pin = credentials.pin { body["pin"] = pin }
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await transport.data(for: request, operation: .tvdb)
            try Self.check(response.statusCode)
            return data
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        guard let data, let response = try? JSONDecoder().decode(TVDBResponse<TVDBLogin>.self, from: data),
            response.status == "success", let value = response.data?.token, !value.isEmpty
        else { throw TVDBError.invalidResponse }
        tokens.insert(value, for: key)
        return value
    }

    private static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw TVDBError.unauthorized
        case 429: throw TVDBError.rateLimited
        case 500...599: throw TVDBError.unavailable
        default: throw TVDBError.invalidResponse
        }
    }

    private func fetch<Value: Codable & Sendable>(
        _ type: Value.Type, path: String,
        credentials: TVDBCredentials, ttl: TimeInterval = 6 * 3600, refresh: Bool = false
    ) async throws -> TVDBResponse<Value>? {
        let key = "tvdb:" + credentials.fingerprint + ":" + path
        let current = generation
        if !refresh, let bytes = memory.value(for: key) {
            return try JSONDecoder().decode(TVDBResponse<Value>.self, from: bytes)
        }
        if !refresh, let cached = await disk?.value(Data.self, key: key, ttl: ttl) {
            if !cached.isFresh {
                await disk?.refresh(key: key) { [self] in
                    _ = try await fetch(type, path: path, credentials: credentials, ttl: ttl, refresh: true)
                }
            }
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            return try JSONDecoder().decode(TVDBResponse<Value>.self, from: cached.value)
        }
        let cacheToken = await disk?.token()
        let bytes = try await requests.value(for: key) { [self] in
            try await download(path: path, credentials: credentials)
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        guard let bytes else { return nil }
        guard let response = try? JSONDecoder().decode(TVDBResponse<Value>.self, from: bytes),
            response.status == "success", response.data != nil
        else { throw TVDBError.invalidResponse }
        // Rarely changing taxonomies use disk TTL only, rather than a shorter memory TTL.
        if ttl == 6 * 3600 { memory.insert(bytes, for: key) }
        await disk?.save(bytes, key: key, token: cacheToken)
        return response
    }

    private func download(path: String, credentials: TVDBCredentials) async throws -> Data? {
        let current = generation
        for attempt in 0...1 {
            let auth = try await token(credentials)
            var request = URLRequest(url: URL(string: "https://api4.thetvdb.com/v4/" + path)!)
            request.setValue("Bearer " + auth, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data, response: HTTPURLResponse
            do {
                (data, response) = try await transport.data(for: request, operation: .tvdb)
            } catch is CancellationError { throw CancellationError() } catch { throw TVDBError.unavailable }
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            if response.statusCode == 404 { return nil }
            if response.statusCode == 401 && attempt == 0 {
                // A concurrent request may already have renewed this token.
                if tokens.value(for: credentials.fingerprint) == auth { tokens.removeAll() }
                continue
            }
            try Self.check(response.statusCode)
            return data
        }
        throw TVDBError.unauthorized
    }

    public func enrichment(for item: MediaItem, credentials: TVDBCredentials, refresh: Bool = false)
        async throws -> MetadataEnrichment?
    {
        guard item.type == "series" else { return nil }
        let current = generation
        let key = Self.detailsKey(item, credentials: credentials)
        let cacheToken = await disk?.token()
        if !refresh, let cached = await disk?.value(MetadataEnrichment.self, key: key, ttl: 6 * 3600) {
            if !cached.isFresh {
                await disk?.refresh(key: key) { [self] in
                    _ = try await enrichment(for: item, credentials: credentials, refresh: true)
                }
            }
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            return cached.value
        }
        let id: Int
        if let known = MediaIdentity.tvdbID(item) {
            id = known
        } else if let imdb = MediaIdentity.validIMDb(item.imdbID) ?? MediaIdentity.validIMDb(item.id) {
            let match = try await fetch(
                [TVDBRemoteMatch].self, path: "search/remoteid/" + imdb,
                credentials: credentials)
            let ids = Set((match?.data ?? []).compactMap { $0.series?.id }.filter { $0 > 0 })
            guard ids.count == 1, let found = ids.first else { return nil }
            id = found
        } else {
            return nil
        }
        guard
            let record = try await fetch(
                TVDBSeries.self,
                path: "series/\(id)/extended?meta=translations", credentials: credentials, refresh: refresh)?
                .data,
            record.id == id
        else { return nil }
        // Missing artwork taxonomy must not make the show's other metadata disappear.
        let types = try? await fetch(
            [TVDBNamedRecord].self, path: "artwork/types",
            credentials: credentials, ttl: 7 * 24 * 3600)?.data
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        let value = record.enrichment(artworkTypes: types ?? [])
        if let known = MediaIdentity.validIMDb(item.imdbID) ?? MediaIdentity.validIMDb(item.id),
            let resolved = value.imdbID, known != resolved
        {
            return nil
        }
        await disk?.save(value, key: key, token: cacheToken)
        return value
    }

    public func episodes(for media: MediaItem, id: Int, season: Int, credentials: TVDBCredentials)
        async throws -> [Episode]
    {
        guard media.type == "series", id > 0, season >= 0 else { throw TVDBError.invalidResponse }
        let records = try await seasonRecords(id: id, season: season, credentials: credentials)
        let imdb = MediaIdentity.validIMDb(media.imdbID) ?? MediaIdentity.validIMDb(media.id)
        let existing = media.videos ?? []
        var numbers = Set<Int>()
        return try records.filter { ($0.number ?? 0) > 0 && numbers.insert($0.number!).inserted }.map { row in
            let number = row.number!
            let saved = existing.first { $0.season == season && $0.episode == number }
            guard let playbackID = saved?.id ?? imdb.map({ "\($0):\(season):\(number)" })
            else { throw TVDBError.missingPlaybackIdentity }
            return Episode(
                id: playbackID, title: row.name?.nonempty ?? saved?.title, name: nil,
                season: season, episode: number, overview: row.overview?.nonempty ?? saved?.overview,
                thumbnail: TVDBImage.url(row.image) ?? saved?.thumbnail,
                released: row.aired ?? saved?.released,
                streams: saved?.streams,
                runtimeMinutes: row.runtime.flatMap { $0 > 0 ? $0 : nil } ?? saved?.runtimeMinutes)
        }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    private func seasonRecords(id: Int, season: Int, credentials: TVDBCredentials, refresh: Bool = false)
        async throws -> [TVDBEpisode]
    {
        let current = generation
        let key = Self.episodesKey(id: id, season: season, credentials: credentials)
        let cacheToken = await disk?.token()
        if !refresh, let cached = await disk?.value([TVDBEpisode].self, key: key, ttl: 6 * 3600) {
            if !cached.isFresh {
                await disk?.refresh(key: key) { [self] in
                    _ = try await seasonRecords(
                        id: id, season: season, credentials: credentials, refresh: true)
                }
            }
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            return cached.value
        }
        var page = 0, seenIDs = Set<Int>(), records: [TVDBEpisode] = []
        while true {
            guard
                let response = try await fetch(
                    TVDBEpisodes.self,
                    path: "series/\(id)/episodes/official?season=\(season)&page=\(page)",
                    credentials: credentials, refresh: refresh),
                let data = response.data, data.series?.id == id, let episodes = data.episodes
            else { throw TVDBError.invalidResponse }
            guard
                episodes.allSatisfy({ ($0.seriesId == nil || $0.seriesId == id) && $0.seasonNumber == season }
                )
            else { throw TVDBError.invalidResponse }
            let fresh = episodes.filter { seenIDs.insert($0.id).inserted }
            records += fresh
            let hasNext = response.links?.next?.isEmpty == false
            if !hasNext { break }
            guard !fresh.isEmpty, page < 499 else { throw TVDBError.invalidResponse }
            // Only advance our own trusted endpoint; never follow provider-supplied URLs with auth.
            page += 1
        }
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        await disk?.save(records, key: key, token: cacheToken)
        return records
    }

    public func tmdbPersonID(_ id: Int, credentials: TVDBCredentials) async throws -> Int? {
        guard id > 0 else { return nil }
        guard
            let person = try await fetch(
                TVDBPerson.self, path: "people/\(id)/extended", credentials: credentials)?.data,
            person.id == id
        else { return nil }
        return person.remoteIds?.compactMap(\.tmdbID).first
    }
}
