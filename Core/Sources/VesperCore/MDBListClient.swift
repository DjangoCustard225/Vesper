import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Third-party scores for one title, as MDBList reports them. A missing score stays nil.
public struct TitleRatings: Codable, Sendable, Equatable {
    /// Out of 10.
    public var imdb: Double?
    /// Tomatometer percentage, 0 to 100.
    public var rottenTomatoes: Int?
    /// Out of 5.
    public var letterboxd: Double?

    public init(imdb: Double? = nil, rottenTomatoes: Int? = nil, letterboxd: Double? = nil) {
        self.imdb = imdb; self.rottenTomatoes = rottenTomatoes; self.letterboxd = letterboxd
    }

    public var isEmpty: Bool { imdb == nil && rottenTomatoes == nil && letterboxd == nil }
}

/// Identifies a title for an MDBList lookup, preferring the IMDb ID.
public struct RatingsTitle: Sendable, Hashable {
    public enum Kind: String, Sendable { case movie, show }
    let kind: Kind
    let provider: String
    let id: String

    public init?(type: String, imdbID: String?, tmdbID: Int?) {
        switch type {
        case "movie": kind = .movie
        case "series": kind = .show
        default: return nil
        }
        if let imdb = MediaIdentity.validIMDb(imdbID) {
            provider = "imdb"; id = imdb
        } else if let tmdbID, tmdbID > 0 {
            provider = "tmdb"; id = String(tmdbID)
        } else {
            return nil
        }
    }

    var key: String { "\(kind.rawValue):\(provider):\(id)" }
}

public enum MDBListError: LocalizedError, Equatable {
    case invalidKey, limitReached, http(Int), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidKey: "MDBList did not accept this API key."
        case .limitReached: "This MDBList key has reached its daily request limit. Try again tomorrow."
        case .http(let status): "MDBList returned an error (\(status))."
        case .invalidResponse: "MDBList returned an unexpected response."
        }
    }
}

/// Reads IMDb, Rotten Tomatoes and Letterboxd scores from MDBList (mdblist.com), which gathers
/// them under one free, user-supplied API key. Results are cached for a day.
public actor MDBListClient {
    private struct Response: Decodable {
        struct Rating: Decodable {
            let source: String
            let value: Double?
        }
        let ratings: [Rating]?
        let error: String?
        let response: Bool?
    }
    private static let lifetime: TimeInterval = 24 * 3600
    private let session: URLSession
    private let ownsSession: Bool
    private let transport: HTTPTransport
    private let disk: ResponseCache?
    private var memory = ExpiringCache<TitleRatings>(lifetime: MDBListClient.lifetime, capacity: 256)
    private var requests = SharedRequestPool<TitleRatings>()
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
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 10
            // The key travels in the query, so never follow a redirect with it.
            self.session = URLSession(
                configuration: configuration, delegate: TMDBRedirectGuard(), delegateQueue: nil)
        }
        disk = cache
        transport = HTTPTransport(
            session: self.session, policy: RetryPolicy(attempts: 2, budget: 10), requestTimeout: 8)
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    public nonisolated static func normalizedKey(_ input: String) throws -> String {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...128).contains(key.count), key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { throw MDBListError.invalidKey }
        return key
    }

    /// Confirms the key works by looking up a well-known film.
    public func validate(key: String) async throws {
        guard let title = RatingsTitle(type: "movie", imdbID: "tt0111161", tmdbID: nil) else { return }
        _ = try await fetch(title, key: key)
    }

    public func ratings(for title: RatingsTitle, key: String, now: Date = Date()) async throws -> TitleRatings
    {
        try Task.checkCancellation()
        if let cached = memory.value(for: title.key, now: now) { return cached }
        let token = generation, requests = requests
        let diskToken = await disk?.token()
        if let cached = await disk?.value(TitleRatings.self, key: title.key, ttl: Self.lifetime, now: now),
            cached.isFresh
        {
            guard token == generation else { throw CancellationError() }
            memory.insert(cached.value, for: title.key, now: cached.savedAt)
            return cached.value
        }
        let value = try await requests.value(for: title.key) { try await self.fetch(title, key: key) }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        memory.insert(value, for: title.key, now: now)
        await disk?.save(value, key: title.key, token: diskToken, now: now)
        return value
    }

    public func clearCache() async throws {
        generation = UUID()
        let previous = requests
        requests = SharedRequestPool()
        memory.removeAll()
        await previous.cancelAll()
        try await disk?.removeAll()
    }

    private func fetch(_ title: RatingsTitle, key: String) async throws -> TitleRatings {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.mdblist.com"
        components.path = "/\(title.provider)/\(title.kind.rawValue)/\(title.id)"
        components.queryItems = [URLQueryItem(name: "apikey", value: key)]
        guard let url = components.url else { throw MDBListError.invalidResponse }
        let (data, response) = try await transport.data(
            for: URLRequest(url: url), operation: .ratings, byteLimit: 512 * 1024)
        switch response.statusCode {
        case 200: break
        case 404: return TitleRatings()
        case 401, 403: throw MDBListError.invalidKey
        case 429: throw MDBListError.limitReached
        default: throw MDBListError.http(response.statusCode)
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw MDBListError.invalidResponse
        }
        // MDBList can report a bad key or an exhausted quota with a 200 and an error body.
        if let error = decoded.error, decoded.ratings == nil {
            throw error.localizedCaseInsensitiveContains("limit") ? MDBListError.limitReached : .invalidKey
        }
        guard decoded.response != false, let ratings = decoded.ratings else {
            throw MDBListError.invalidResponse
        }
        return Self.ratings(from: ratings)
    }

    private static func ratings(from list: [Response.Rating]) -> TitleRatings {
        func value(_ source: String, in range: ClosedRange<Double>) -> Double? {
            list.first { $0.source == source }?.value.flatMap { $0 > 0 && range.contains($0) ? $0 : nil }
        }
        return TitleRatings(
            imdb: value("imdb", in: 0...10),
            rottenTomatoes: value("tomatoes", in: 0...100).map { Int($0.rounded()) },
            letterboxd: value("letterboxd", in: 0...5))
    }
}
