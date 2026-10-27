import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor IntroDBClient {
    private struct CachedIntro: Codable, Sendable { let segment: IntroSegment? }
    private struct Response: Decodable {
        struct Segment: Decodable { let startMs: Double; let endMs: Double }
        let imdbId: String
        let season: Int
        let episode: Int
        let isMovie: Bool?
        let noIntro: Bool?
        let intro: Segment?
    }
    enum Failure: Error { case invalidResponse, http(Int) }
    private let session: URLSession
    private let ownsSession: Bool
    private let transport: HTTPTransport
    private let disk: ResponseCache?
    private var positives = ExpiringCache<IntroSegment>(lifetime: 24 * 3600, capacity: 128)
    private var negatives = ExpiringCache<Bool>(lifetime: 3600, capacity: 128)
    private var requests = SharedRequestPool<CachedIntro>()
    private var generation = UUID()

    public init(session: URLSession? = nil, cache: ResponseCache? = nil) {
        ownsSession = session == nil
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 4
            configuration.timeoutIntervalForResource = 4
            self.session = URLSession(
                configuration: configuration, delegate: TMDBRedirectGuard(), delegateQueue: nil)
        }
        disk = cache
        transport = HTTPTransport(
            session: self.session, policy: RetryPolicy(attempts: 1, budget: 4), requestTimeout: 4)
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    public func segment(for episode: IntroEpisode, now: Date = Date()) async throws -> IntroSegment? {
        try Task.checkCancellation()
        if let segment = positives.value(for: episode.key, now: now) { return segment }
        if negatives.value(for: episode.key, now: now) != nil { return nil }
        let token = generation, requests = requests
        let diskToken = await disk?.token()
        if let cached = await disk?.value(CachedIntro.self, key: episode.key, ttl: 24 * 3600, now: now),
            cached.isFresh, cached.value.segment != nil || now.timeIntervalSince(cached.savedAt) < 3600
        {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            remember(cached.value, key: episode.key, now: cached.savedAt)
            return cached.value.segment
        }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        let value = try await requests.value(for: episode.key) { try await self.fetch(episode) }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        remember(value, key: episode.key, now: now)
        await disk?.save(value, key: episode.key, token: diskToken, now: now)
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        return value.segment
    }

    public func clearCache() async throws {
        generation = UUID()
        let previous = requests
        requests = SharedRequestPool()
        positives.removeAll()
        negatives.removeAll()
        await previous.cancelAll()
        try await disk?.removeAll()
    }

    private func remember(_ value: CachedIntro, key: String, now: Date) {
        if let segment = value.segment {
            positives.insert(segment, for: key, now: now)
        } else {
            negatives.insert(true, for: key, now: now)
        }
    }

    private func fetch(_ episode: IntroEpisode) async throws -> CachedIntro {
        var components = URLComponents(string: "https://api.introdb.app/segments")!
        components.queryItems = [
            .init(name: "imdb_id", value: episode.imdbID),
            .init(name: "season", value: String(episode.season)),
            .init(name: "episode", value: String(episode.episode)),
        ]
        let (data, response) = try await transport.data(
            for: URLRequest(url: components.url!), operation: .introSegments, byteLimit: 64 * 1024)
        if response.statusCode == 404 { return CachedIntro(segment: nil) }
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(Response.self, from: data)
        guard decoded.imdbId == episode.imdbID, decoded.season == episode.season,
            decoded.episode == episode.episode, decoded.isMovie != true
        else { throw Failure.invalidResponse }
        guard decoded.noIntro != true, let intro = decoded.intro else { return CachedIntro(segment: nil) }
        guard let segment = IntroSegment(startMilliseconds: intro.startMs, endMilliseconds: intro.endMs)
        else { throw Failure.invalidResponse }
        return CachedIntro(segment: segment)
    }
}
