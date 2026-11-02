import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SimklTokens: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
}

public struct SimklDeviceCode: Decodable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let expiresIn: Int
    public let interval: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code"
        case verificationURI = "verification_uri", expiresIn = "expires_in", interval
    }
}

public enum SimklError: LocalizedError {
    case response, reconnect, pending, slowDown, expired, unidentified, rateLimited, rejected(Int)
    public var errorDescription: String? {
        switch self {
        case .response: "SIMKL returned an unexpected response."
        case .reconnect: "Reconnect your SIMKL account to continue."
        case .pending: "Waiting for SIMKL authorization."
        case .slowDown, .rateLimited: "SIMKL is limiting requests. Try again shortly."
        case .expired: "The sign-in code expired. Start again."
        case .unidentified: "This title or episode could not be identified for SIMKL."
        case .rejected(let code): "SIMKL could not complete the request (\(code))."
        }
    }
}

/// Account tokens belong in Keychain. The client never persists request bodies or playback URLs.
public actor SimklClient {
    public static let clientID = "1111418e74175b198ea5b7a66f7ef559f4dcd0af76f76ceb8d3e7aee0b3007c7"
    private let session: URLSession
    private let persist: @Sendable (SimklTokens?) throws -> Void
    private var tokens: SimklTokens?
    private var generation = UUID()
    private var refresh: Task<SimklTokens, Error>?

    public init(
        tokens: SimklTokens? = nil, session: URLSession? = nil,
        persist: @escaping @Sendable (SimklTokens?) throws -> Void = { _ in }
    ) {
        self.tokens = tokens
        self.persist = persist
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        self.session =
            session
            ?? URLSession(configuration: configuration, delegate: SimklRedirectGuard(), delegateQueue: nil)
    }

    public func beginAuthorization() async throws -> SimklDeviceCode {
        let data = try await request(
            "oauth2/device", body: ["client_id": Self.clientID, "scope": "media:read media:write"])
        let code = try JSONDecoder().decode(SimklDeviceCode.self, from: data)
        guard code.verificationURI.scheme == "https", code.verificationURI.host == "simkl.com",
            code.verificationURI.path == "/pin", code.expiresIn > 0, code.interval > 0
        else { throw SimklError.response }
        return code
    }

    public func poll(_ code: SimklDeviceCode) async throws {
        let revision = generation
        let value = try await exchange([
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code", "device_code": code.deviceCode,
        ])
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        try persist(value)
        tokens = value
    }

    /// Keep the same code alive across temporary disconnections while the user approves in Safari.
    public func waitForAuthorization(
        _ code: SimklDeviceCode,
        wait: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) async throws {
        let revision = generation
        let deadline = Date().addingTimeInterval(Double(min(code.expiresIn, 900)))
        let minimum = Double(max(5, code.interval))
        var interval = minimum
        while Date() < deadline {
            try await wait(interval)
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
            guard Date() < deadline else { throw SimklError.expired }
            do {
                try await poll(code)
                return
            } catch SimklError.pending {
                continue
            } catch SimklError.slowDown {
                interval = min(60, interval + 5)
            } catch SimklError.rateLimited {
                interval = max(60, interval)
            } catch {
                try Task.checkCancellation()
                let failure = error as NSError
                guard failure.domain == NSURLErrorDomain,
                    [
                        URLError.networkConnectionLost, .timedOut, .notConnectedToInternet,
                        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .cancelled,
                    ]
                    .contains(where: { $0.rawValue == failure.code })
                else { throw error }
                interval = min(60, max(minimum, interval * 2))
            }
        }
        throw SimklError.expired
    }

    public func disconnect() throws {
        try persist(nil)
        generation = UUID()
        refresh?.cancel()
        refresh = nil
        tokens = nil
    }

    public func scrobble(_ event: TraktScrobbleEvent, media: MediaItem, videoID: String) async throws {
        var body: [String: Any] = ["progress": event.progress.isFinite ? min(100, max(0, event.progress)) : 0]
        body[media.type == "movie" ? "movie" : "show"] = try Self.identity(media)
        if media.type == "series" {
            guard let episode = TraktClient.episode(videoID) else { throw SimklError.unidentified }
            body["episode"] = ["season": episode.season, "number": episode.number]
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let data = try await request(
            "scrobble/\(event.action.rawValue)", payload: payload, token: try await accessToken())
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let action = result["action"] as? String,
            ["start", "pause", "stop", "scrobble"].contains(action)
        else { throw SimklError.response }
    }

    public func setWatched(_ watched: Bool, media: MediaItem, videoID: String?) async throws {
        var item = try Self.identity(media)
        if media.type == "series", let videoID {
            guard let episode = TraktClient.episode(videoID) else { throw SimklError.unidentified }
            item["seasons"] = [["number": episode.season, "episodes": [["number": episode.number]]]]
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            media.type == "movie" ? "movies" : "shows": [item]
        ])
        let data = try await request(
            watched ? "sync/history" : "sync/history/remove", payload: payload, token: try await accessToken()
        )
        if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let missing = result["not_found"] as? [String: Any],
            missing.values.contains(where: { ($0 as? [Any])?.isEmpty == false })
        {
            throw SimklError.unidentified
        }
    }

    public func accountID() async throws -> String {
        let data = try await get("users/settings")
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let account = root?["account"] as? [String: Any], let id = account["id"], !(id is NSNull) else {
            throw SimklError.response
        }
        return String(describing: id)
    }

    public func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await request(path, payload: Data(), token: try await accessToken(), method: "GET", query: query)
    }

    static func identity(_ media: MediaItem) throws -> [String: Any] {
        guard media.type == "movie" || media.type == "series" else { throw SimklError.unidentified }
        var ids: [String: Any] = [:]
        if let imdb = MediaIdentity.validIMDb(media.imdbID) ?? MediaIdentity.validIMDb(media.id) {
            ids["imdb"] = imdb
        }
        if let tmdb = MediaIdentity.tmdbID(media), tmdb > 0 { ids["tmdb"] = tmdb }
        if let tvdb = MediaIdentity.tvdbID(media), tvdb > 0 { ids["tvdb"] = tvdb }
        guard !ids.isEmpty else { throw SimklError.unidentified }
        return ["ids": ids]
    }

    private func accessToken() async throws -> String {
        guard let tokens else { throw SimklError.reconnect }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        let revision = generation
        if refresh == nil {
            refresh = Task {
                try await self.exchange(["grant_type": "refresh_token", "refresh_token": tokens.refreshToken])
            }
        }
        let value: SimklTokens
        do { value = try await refresh!.value } catch {
            if revision == generation { refresh = nil }
            throw error
        }
        guard revision == generation else { throw CancellationError() }
        if refresh != nil {
            defer { refresh = nil }
            try persist(value)
            self.tokens = value
        }
        return value.accessToken
    }

    private func exchange(_ fields: [String: String]) async throws -> SimklTokens {
        var body = fields
        body["client_id"] = Self.clientID
        let data = try await request("oauth2/token", body: body)
        struct Response: Decodable {
            let access_token: String; let refresh_token: String; let expires_in: Int; let scope: String
        }
        let value = try JSONDecoder().decode(Response.self, from: data)
        guard !value.access_token.isEmpty, !value.refresh_token.isEmpty, value.expires_in > 0,
            value.scope.split(separator: " ").contains("media:write")
        else { throw SimklError.reconnect }
        return SimklTokens(
            accessToken: value.access_token, refreshToken: value.refresh_token,
            expiresAt: Date().addingTimeInterval(Double(value.expires_in)))
    }

    private func request(_ path: String, body: [String: String]) async throws -> Data {
        try await request(path, payload: JSONSerialization.data(withJSONObject: body))
    }

    private func request(
        _ path: String, payload: Data, token: String? = nil, method: String = "POST",
        query: [URLQueryItem] = []
    ) async throws -> Data {
        var url = URLComponents(string: "https://api.simkl.com/\(path)")!
        url.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "app-name", value: "Vesper"), URLQueryItem(name: "app-version", value: "0.5"),
        ]
        url.queryItems! += query
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        request.httpBody = method == "GET" ? nil : payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Vesper/0.5", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await BoundedResponse.data(
            for: request, session: session, limit: 64 * 1024 * 1024)
        try Task.checkCancellation()

        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch object?["error"] as? String {
            case "authorization_pending": throw SimklError.pending
            case "slow_down": throw SimklError.slowDown
            case "expired_token": throw SimklError.expired
            default: break
            }
            if response.statusCode == 401 { throw SimklError.reconnect }
            if response.statusCode == 429 { throw SimklError.rateLimited }
            throw SimklError.rejected(response.statusCode)
        }
        return data
    }
}

private final class SimklRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
