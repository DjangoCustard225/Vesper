import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SubDLSubtitle: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let url: URL
    public let season: Int?
    public let episode: Int?

    public init(
        id: String, name: String, language: String, url: URL, season: Int? = nil, episode: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.url = url
        self.season = season
        self.episode = episode
    }
}

public enum SubDLError: LocalizedError {
    case keyRequired, unidentified, response, archive, rejected(Int)
    public var errorDescription: String? {
        switch self {
        case .keyRequired: "Add your SubDL API key in Settings."
        case .unidentified: "This title or episode could not be identified."
        case .response: "SubDL returned an unexpected response."
        case .archive: "Couldn’t extract a matching subtitle. Try another result."
        case .rejected(let code):
            code == 401 || code == 403
                ? "Check your SubDL API key and account access."
                : code == 429
                    ? "SubDL’s request limit was reached. Try again later."
                    : "SubDL could not complete the request (\(code))."
        }
    }
}

public actor SubDLClient {
    private let key: String
    private let session: URLSession
    private let ownsSession: Bool

    public init(key: String, session: URLSession? = nil) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        ownsSession = session == nil
        self.session =
            session ?? URLSession(configuration: .ephemeral, delegate: SubDLRedirects(), delegateQueue: nil)
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    public func search(media: MediaItem, videoID: String?, language: String) async throws -> [SubDLSubtitle] {
        var query = [
            URLQueryItem(name: "type", value: media.type == "movie" ? "movie" : "tv"),
            URLQueryItem(name: "languages", value: language), URLQueryItem(name: "unpack", value: "1"),
        ]
        guard ["movie", "series"].contains(media.type) else { throw SubDLError.unidentified }
        if let imdb = MediaIdentity.validIMDb(media.imdbID) ?? MediaIdentity.validIMDb(media.id) {
            query.append(URLQueryItem(name: "imdb_id", value: imdb))
        } else if let tmdb = MediaIdentity.tmdbID(media) {
            query.append(URLQueryItem(name: "tmdb_id", value: String(tmdb)))
        } else {
            throw SubDLError.unidentified
        }
        let episode = media.type == "series" ? TraktClient.episode(videoID) : nil
        if media.type == "series" {
            guard let episode else { throw SubDLError.unidentified }
            query += [
                URLQueryItem(name: "season", value: String(episode.season)),
                URLQueryItem(name: "episode", value: String(episode.number)),
            ]
        }
        var components = URLComponents(string: "https://api.subdl.com/api/v2/subtitles/search")!
        components.queryItems = query
        let data = try await fetch(components.url!, limit: 4 * 1024 * 1024)
        return try Self.subtitles(
            from: data, language: language, season: episode?.season, episode: episode?.number)
    }

    private static func subtitles(
        from data: Data, language: String, season: Int?, episode: Int?
    ) throws -> [SubDLSubtitle] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubDLError.response
        }
        if root["status"] as? Bool == false {
            // SubDL can reject a key or a quota inside a successful HTTP response.
            let message = (root["error"] as? String ?? root["message"] as? String ?? "").lowercased()
            if message.contains("limit") || message.contains("too many") { throw SubDLError.rejected(429) }
            if message.contains("key") || message.contains("auth") || message.contains("token") {
                throw SubDLError.rejected(401)
            }
            throw SubDLError.response
        }
        let nested = root["data"] as? [String: Any]
        guard let rows = root["subtitles"] as? [[String: Any]] ?? nested?["subtitles"] as? [[String: Any]]
        else { throw SubDLError.response }
        var seen = Set<String>()
        var results: [SubDLSubtitle] = []
        for row in rows {
            let name =
                row["release_name"] as? String ?? row["file_name"] as? String ?? row["name"] as? String
                ?? "Subtitle"
            let lang = row["lang"] as? String ?? row["language"] as? String ?? language
            let files = row["unpack_files"] as? [[String: Any]] ?? []
            for file in files {
                func number(_ key: String) -> Int? { file[key].flatMap { Int(String(describing: $0)) } }
                if let season, let value = number("season"), value != season { continue }
                if let episode, let value = number("episode"), value != episode { continue }
                guard let raw = file["url"] as? String, let url = Self.downloadURL(raw),
                    seen.insert(url.absoluteString).inserted
                else { continue }
                let filename = file["name"] as? String ?? file["release_name"] as? String ?? name
                let fileLanguage = file["language"] as? String ?? lang
                results.append(
                    SubDLSubtitle(
                        id: url.absoluteString, name: filename, language: fileLanguage, url: url,
                        season: season, episode: episode))
            }
            let url =
                (row["download_url"] as? String ?? row["url"] as? String).flatMap(downloadURL)
                ?? identifierURL(row["n_id"] ?? row["nId"] ?? row["id"])
            if let url, seen.insert(url.absoluteString).inserted {
                results.append(
                    SubDLSubtitle(
                        id: url.absoluteString, name: name, language: lang, url: url, season: season,
                        episode: episode))
            }
        }
        if !rows.isEmpty && results.isEmpty { throw SubDLError.response }
        return results
    }

    private static func identifierURL(_ value: Any?) -> URL? {
        guard let value else { return nil }
        let id = String(describing: value)
        guard !id.isEmpty, id.count <= 200,
            id.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 95
            })
        else { return nil }
        var endpoint = URLComponents(string: "https://api.subdl.com/api/v2/subtitles/\(id)/download")!
        endpoint.queryItems = [URLQueryItem(name: "format", value: "file")]
        return endpoint.url
    }

    private static func downloadURL(_ raw: String) -> URL? {
        guard let direct = URL(string: raw, relativeTo: URL(string: "https://dl.subdl.com"))?.absoluteURL,
            allowed(direct), !direct.path.isEmpty
        else { return nil }
        return direct
    }

    /// Confirms the key with one search for a well-known film.
    public func validate() async throws {
        _ = try await search(
            media: MediaItem(id: "tt0111161", type: "movie", name: "The Shawshank Redemption"), videoID: nil,
            language: "en")
    }

    /// Subtitles are handed to the player as files; drop any left from earlier sessions.
    public static func removeOldDownloads(olderThan age: TimeInterval = 86_400, now: Date = Date()) {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("VesperSubDL", isDirectory: true)
        guard
            let files = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, now.timeIntervalSince(modified) > age { try? manager.removeItem(at: file) }
        }
    }

    public func download(_ subtitle: SubDLSubtitle) async throws -> URL {
        let download = try await fetch(subtitle.url, limit: 8 * 1024 * 1024)
        let data =
            download.starts(with: [0x50, 0x4b])
            ? try SubDLArchive.subtitle(from: download, season: subtitle.season, episode: subtitle.episode)
            : download
        guard !data.isEmpty,
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .windowsCP1252),
            text.contains("-->") || text.contains("[Events]")
        else { throw SubDLError.archive }
        let ext =
            text.contains("[Events]")
            ? "ass" : text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") ? "vtt" : "srt"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VesperSubDL", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try Task.checkCancellation()
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard !key.isEmpty else { throw SubDLError.keyRequired }
        guard Self.allowed(url) else { throw SubDLError.response }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await BoundedResponse.data(for: request, session: session, limit: limit)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else {
            throw SubDLError.rejected(response.statusCode)
        }
        return data
    }

    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && ["api.subdl.com", "dl.subdl.com"].contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }
}

private final class SubDLRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(SubDLClient.allowed) == true ? request : nil)
    }
}
