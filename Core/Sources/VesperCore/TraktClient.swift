import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Owns OAuth rotation and request pacing. Credentials never enter the response cache or diagnostics.
public actor TraktClient {
    public static let vesperClientID = "Fccb6wS0TQqlYiz4KxdyAZqt4q2jjT-sPf28K4P74dM"
    private let clientID: String
    private let transport: HTTPTransport
    private let persistTokens: @Sendable (TraktTokens?) throws -> Void
    private var tokens: TraktTokens?
    private var pendingRotation: TraktTokens?
    private var generation = UUID()
    private var deviceCode: String?
    private var refreshTask: (id: UUID, task: Task<TraktTokens, Error>)?
    private var nextWrite = Date.distantPast
    private var resolved: [String: ResolvedTitle] = [:]

    public init(
        clientID: String = TraktClient.vesperClientID, tokens: TraktTokens? = nil,
        session: URLSession = URLSession(configuration: .ephemeral),
        diagnostics: DiagnosticRecorder = .shared,
        persistTokens: @escaping @Sendable (TraktTokens?) throws -> Void = { _ in }
    ) {
        self.clientID = clientID
        self.tokens = tokens
        self.persistTokens = persistTokens
        transport = HTTPTransport(session: session, diagnostics: diagnostics)
    }

    public func beginAuthorization() async throws -> TraktDeviceCode {
        let revision = generation
        let data = try await auth("oauth/device/code", body: ["client_id": clientID])
        let code = try decode(TraktDeviceCode.self, data)
        guard revision == generation, code.isValid else { throw TraktError.invalidResponse }
        deviceCode = code.deviceCode
        return code
    }

    public func cancelAuthorization() { deviceCode = nil }

    /// The caller owns the polling deadline and interval so a dismissed sheet immediately stops work.
    public func pollAuthorization(_ code: TraktDeviceCode) async throws -> Bool {
        guard deviceCode == code.deviceCode else { throw CancellationError() }
        let revision = generation
        let (data, http) = try await raw(
            "oauth/device/token", method: "POST",
            body: ["code": code.deviceCode, "client_id": clientID], authentication: true)
        guard revision == generation, deviceCode == code.deviceCode else { throw CancellationError() }
        switch http.statusCode {
        case 200:
            let value = try decode(TraktTokens.self, data)
            guard value.isValid else { throw TraktError.invalidResponse }
            try persistTokens(value)
            tokens = value
            deviceCode = nil
            return true
        case 400: return false
        case 404, 409, 410: throw TraktError.authorizationExpired
        case 418: throw TraktError.denied
        default: throw failure(http)
        }
    }

    public func account() async throws -> TraktAccount {
        let value = try decode(TraktUserSettings.self, await request("users/settings"))
        guard !value.user.id.isEmpty else { throw TraktError.invalidResponse }
        return value.user
    }

    public func disconnect() async throws {
        let previous = tokens
        // Local deletion happens before any network work; failed revocation cannot keep syncing enabled.
        try persistTokens(nil)
        tokens = nil
        pendingRotation = nil
        generation = UUID()
        deviceCode = nil
        refreshTask?.task.cancel()
        refreshTask = nil
        resolved = [:]
        if let previous {
            Task {
                _ = try? await self.auth(
                    "oauth/revoke", body: ["token": previous.accessToken, "client_id": self.clientID])
            }
        }
    }

    public struct Snapshot: Sendable {
        public let entries: [TraktWatchedEntry]
        public let fingerprint: String
    }

    public func watched(previousFingerprint: String?) async throws -> Snapshot? {
        struct Activities: Decodable { let all: String }
        let activities = try decode(Activities.self, await request("sync/last_activities"))
        guard activities.all != previousFingerprint else { return nil }
        let movies = try await watchedPages(TraktWatchedMovie.self, path: "sync/watched/movies")
        let shows = try await watchedPages(
            TraktWatchedShow.self, path: "sync/watched/shows?extended=progress")
        var entries: [TraktWatchedEntry] = movies.compactMap { value in
            guard let media = value.movie.media(type: "movie"),
                let date = TraktDates.parse(value.lastWatchedAt)
            else { return nil }
            return TraktWatchedEntry(media: media, watchedAt: date)
        }
        for value in shows {
            guard let media = value.show.media(type: "series") else { continue }
            for season in value.seasons where season.number >= 0 {
                for episode in season.episodes where episode.number > 0 {
                    guard let date = TraktDates.parse(episode.lastWatchedAt) else { continue }
                    entries.append(
                        TraktWatchedEntry(
                            media: media, videoID: "\(media.playbackID):\(season.number):\(episode.number)",
                            watchedAt: date))
                }
            }
            let completed = value.seasons.filter { $0.number > 0 }.reduce(0) { $0 + $1.episodes.count }
            if let aired = value.show.airedEpisodes, aired > 0, completed >= aired,
                let date = TraktDates.parse(value.lastWatchedAt)
            {
                entries.append(TraktWatchedEntry(media: media, watchedAt: date))
            }
        }
        let recentEntries = entries.sorted { $0.watchedAt > $1.watchedAt }.prefix(2_000)
        return Snapshot(entries: Array(recentEntries), fingerprint: activities.all)
    }

    /// Refreshes watched episode state for one series without downloading the account's full history.
    public func watchedEpisodes(for media: MediaItem) async throws -> [TraktWatchedEntry] {
        guard media.type == "series" else { return [] }
        let title = try await resolve(media, videoID: nil)
        guard let id = title.ids.trakt else { throw TraktError.unidentifiedTitle }
        struct Progress: Decodable {
            struct Season: Decodable {
                struct Episode: Decodable {
                    let number: Int
                    let completed: Bool
                    let lastWatchedAt: String?

                    enum CodingKeys: String, CodingKey {
                        case number, completed
                        case lastWatchedAt = "last_watched_at"
                    }
                }

                let number: Int
                let episodes: [Episode]
            }

            let seasons: [Season]
        }
        let progress = try decode(
            Progress.self,
            await request("shows/\(id)/progress/watched?specials=true&hidden=true"))
        return progress.seasons.flatMap { season in
            season.episodes.compactMap { episode in
                guard season.number >= 0, episode.number > 0, episode.completed else { return nil }
                let date = episode.lastWatchedAt.flatMap(TraktDates.parse) ?? .distantPast
                return TraktWatchedEntry(
                    media: media,
                    videoID: "\(media.playbackID):\(season.number):\(episode.number)", watchedAt: date)
            }
        }
    }

    private func watchedPages<Item: Decodable>(_ type: Item.Type, path: String) async throws -> [Item] {
        let pageSize = 100
        var values: [Item] = []
        for page in 1...200 {
            let separator = path.contains("?") ? "&" : "?"
            let data = try await request("\(path)\(separator)page=\(page)&limit=\(pageSize)")
            let current = try decode([Item].self, data)
            values.append(contentsOf: current)
            if current.count < pageSize { return values }
        }
        throw TraktError.historyLimitReached
    }

    #if !VESPER_GO
    public func scrobble(
        _ action: TraktScrobbleAction, media: MediaItem, videoID: String, progress: Double
    ) async throws {
        guard progress.isFinite else { return }
        let title = try await resolve(media, videoID: videoID)
        let body = try scrobbleBody(title, progress: progress)
        do {
            struct Result: Decodable { let action: String }
            let data = try await request("scrobble/" + action.rawValue, method: "POST", encodedBody: body)
            let result = try decode(Result.self, data)
            let expected = action == .stop ? ["scrobble", "pause"] : [action.rawValue]
            guard expected.contains(result.action) else { throw TraktError.invalidResponse }
        } catch TraktError.http(409) where action == .stop {
            // Trakt rejected a duplicate completion; it is already represented in history.
        } catch TraktError.http(422) where action == .stop && progress < 1 {
            // Trakt intentionally ignores stops below one percent.
        }
    }
    #endif

    public func apply(_ change: TraktHistoryChange) async throws {
        let title = try await resolve(change.media, videoID: change.videoID)
        #if !VESPER_GO
        if change.action == .stopped, let progress = change.progress,
            Date().timeIntervalSince(change.date) < 300
        {
            try await scrobble(
                .stop, media: change.media, videoID: change.videoID ?? change.media.playbackID,
                progress: progress)
            return
        }
        #endif
        // Reconcile a queued addition before retrying: /sync/history does not deduplicate timestamps.
        if change.watched, try await alreadyApplied(change, title: title) { return }
        struct Item: Encodable { let ids: TraktIDs; let watched_at: String? }
        let value = Item(ids: title.ids, watched_at: change.watched ? TraktDates.string(change.date) : nil)
        let body = try JSONEncoder().encode([title.collection: [value]])
        let data = try await request(
            change.watched ? "sync/history" : "sync/history/remove", method: "POST", encodedBody: body)
        struct Result: Decodable { let not_found: [String: [TraktMissingItem]]? }
        let result = try decode(Result.self, data)
        if result.not_found?.values.contains(where: { !$0.isEmpty }) == true {
            throw TraktError.unidentifiedTitle
        }
    }

    private struct TraktMissingItem: Decodable {}
    private struct ResolvedTitle: Sendable {
        let ids: TraktIDs
        let kind: String
        var collection: String { kind + "s" }
    }

    private func alreadyApplied(_ change: TraktHistoryChange, title: ResolvedTitle) async throws -> Bool {
        guard let id = title.ids.trakt else { return false }
        if title.kind == "show", change.action == .watched {
            struct Progress: Decodable { let aired: Int; let completed: Int }
            let value = try decode(
                Progress.self, await request("shows/\(id)/progress/watched?specials=false"))
            return value.aired > 0 && value.completed >= value.aired
        }
        #if !VESPER_GO
        var path = "sync/history/\(title.collection)/\(id)?limit=1"
        if change.action == .stopped {
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "start_at", value: TraktDates.string(change.date.addingTimeInterval(-60))),
                URLQueryItem(name: "end_at", value: TraktDates.string(change.date.addingTimeInterval(60))),
            ]
            path += "&" + (components.percentEncodedQuery ?? "")
        }
        #else
        let path = "sync/history/\(title.collection)/\(id)?limit=1"
        #endif
        struct History: Decodable { let id: Int64 }
        return !(try decode([History].self, await request(path))).isEmpty
    }

    private func resolve(_ media: MediaItem, videoID: String?) async throws -> ResolvedTitle {
        guard WatchProgress.supports(media), let lookup = TraktIDs(media).lookup else {
            throw TraktError.unidentifiedTitle
        }
        let kind = media.type == "movie" ? "movie" : "show"
        let episode = media.type == "series" ? Self.episode(videoID) : nil
        if media.type == "series", videoID != nil, episode == nil { throw TraktError.unidentifiedTitle }
        if episode != nil, let videoID {
            let parent = videoID.split(separator: ":").dropLast(2).joined(separator: ":")
            guard MediaItem(id: parent, type: media.type, name: media.name).isSameTitle(as: media) else {
                throw TraktError.unidentifiedTitle
            }
        }
        let key = "\(kind):\(lookup.type):\(lookup.value):\(episode?.season ?? -1):\(episode?.number ?? -1)"
        if let value = resolved[key] { return value }
        struct Match: Decodable { let movie: TraktTitle?; let show: TraktTitle? }
        let matches = try decode(
            [Match].self, await request("search/\(lookup.type)/\(lookup.value)?type=\(kind)"))
        let titles = matches.compactMap { kind == "movie" ? $0.movie : $0.show }.filter {
            switch lookup.type {
            case "imdb": $0.ids.imdb == lookup.value
            case "tmdb": $0.ids.tmdb.map(String.init) == lookup.value
            default: $0.ids.trakt.map(String.init) == lookup.value
            }
        }
        guard titles.count == 1, let title = titles.first, let id = title.ids.trakt else {
            throw TraktError.unidentifiedTitle
        }
        let result: ResolvedTitle
        if let episode {
            struct Episode: Decodable { let ids: TraktIDs }
            let value = try decode(
                Episode.self,
                await request("shows/\(id)/seasons/\(episode.season)/episodes/\(episode.number)"))
            guard let id = value.ids.trakt else { throw TraktError.unidentifiedTitle }
            result = ResolvedTitle(ids: TraktIDs(trakt: id), kind: "episode")
        } else {
            result = ResolvedTitle(ids: TraktIDs(trakt: id), kind: kind)
        }
        if resolved.count >= 256 { resolved.removeAll() }
        resolved[key] = result
        return result
    }

    static func episode(_ videoID: String?) -> (season: Int, number: Int)? {
        guard let parts = videoID?.split(separator: ":"), parts.count >= 3,
            let season = Int(parts[parts.count - 2]), season >= 0,
            let episode = Int(parts[parts.count - 1]), episode > 0
        else { return nil }
        return (season, episode)
    }

    #if !VESPER_GO
    private func scrobbleBody(_ title: ResolvedTitle, progress: Double) throws -> Data {
        struct Item: Encodable { let ids: TraktIDs }
        struct Body: Encodable {
            let progress: Double
            let movie: Item?
            let episode: Item?
        }
        return try JSONEncoder().encode(
            Body(
                progress: min(100, max(0, progress)),
                movie: title.kind == "movie" ? Item(ids: title.ids) : nil,
                episode: title.kind == "episode" ? Item(ids: title.ids) : nil))
    }
    #endif

    private func accessToken(force: Bool = false, replacing: String? = nil) async throws -> TraktTokens {
        if let pendingRotation {
            try persistTokens(pendingRotation)
            tokens = pendingRotation
            self.pendingRotation = nil
        }
        guard let tokens else { throw TraktError.notConnected }
        if let replacing, tokens.accessToken != replacing { return tokens }
        if !force, tokens.expiresAt.timeIntervalSinceNow > 120 { return tokens }
        if let refreshTask { return try await refreshTask.task.value }
        let revision = generation, id = UUID()
        let task = Task<TraktTokens, Error> {
            let data = try await self.auth(
                "oauth/token",
                body: [
                    "client_id": self.clientID, "refresh_token": tokens.refreshToken,
                    "grant_type": "refresh_token",
                ])
            let value = try self.decode(TraktTokens.self, data)
            try Task.checkCancellation()
            guard self.generation == revision, value.isValid else { throw CancellationError() }
            // Persist the rotating refresh token before allowing any subsequent request to use it.
            self.pendingRotation = value
            try self.persistTokens(value)
            self.tokens = value
            self.pendingRotation = nil
            return value
        }
        refreshTask = (id, task)
        defer { if refreshTask?.id == id { refreshTask = nil } }
        do { return try await task.value } catch TraktError.http(400) { throw TraktError.reconnect }
    }

    private func request(_ path: String, method: String = "GET", encodedBody: Data? = nil) async throws
        -> Data
    {
        let revision = generation
        let value = try await accessToken()
        guard revision == generation else { throw CancellationError() }
        var response = try await raw(path, method: method, encodedBody: encodedBody, token: value.accessToken)
        if response.1.statusCode == 401 {
            let refreshed = try await accessToken(force: true, replacing: value.accessToken)
            guard revision == generation else { throw CancellationError() }
            response = try await raw(
                path, method: method, encodedBody: encodedBody, token: refreshed.accessToken)
        }
        guard revision == generation else { throw CancellationError() }
        guard (200..<300).contains(response.1.statusCode) else { throw failure(response.1) }
        return response.0
    }

    private func auth(_ path: String, body: [String: String]) async throws -> Data {
        let result = try await raw(path, method: "POST", body: body, authentication: true)
        guard (200..<300).contains(result.1.statusCode) else { throw failure(result.1) }
        return result.0
    }

    private func raw(
        _ path: String, method: String, body: [String: String]? = nil, encodedBody: Data? = nil,
        token: String? = nil, authentication: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        guard
            let url = URL(
                string: (authentication ? "https://auth.trakt.tv/" : "https://api.trakt.tv/") + path)
        else {
            throw TraktError.invalidResponse
        }
        if method != "GET" {
            let reserved = max(Date(), nextWrite)
            nextWrite = reserved.addingTimeInterval(1.1)
            if reserved > Date() { try await Task.sleep(for: .seconds(reserved.timeIntervalSinceNow)) }
        }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try encodedBody ?? body.map { try JSONEncoder().encode($0) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue("Vesper", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        #if !VESPER_GO
        let operation: NetworkOperation
        switch path {
        case "scrobble/start": operation = .traktScrobbleStart
        case "scrobble/pause": operation = .traktScrobblePause
        case "scrobble/stop": operation = .traktScrobbleStop
        default: operation = .trakt
        }
        #else
        let operation: NetworkOperation = .trakt
        #endif
        return try await transport.data(for: request, operation: operation)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw TraktError.invalidResponse }
    }

    private func failure(_ http: HTTPURLResponse) -> TraktError {
        switch http.statusCode {
        case 401: .reconnect
        case 420: .accountLimit
        case 429: .rateLimited(max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30))
        default: .http(http.statusCode)
        }
    }
}
