import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AddonError: LocalizedError, Equatable {
    case invalidURL, invalidManifest, configurationRequired, http(Int), invalidResponse, network, unsupportedStream, serverRequired, invalidTorrent
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTP or HTTPS URL."
        case .invalidManifest: "This endpoint did not return a valid add-on manifest."
        case .configurationRequired: "Configure this add-on on its website, then paste the generated manifest URL."
        case .http(let status): "The add-on returned HTTP \(status). Try again or check its configuration."
        case .invalidResponse: "The add-on returned an unreadable response."
        case .network: "Couldn’t connect. Check your connection and the add-on address."
        case .unsupportedStream: "This source can’t play in the native player. Choose an HTTP video source or an external link."
        case .serverRequired: "Set your Stremio streaming server in Settings to play this source."
        case .invalidTorrent: "The add-on returned an invalid torrent hash or file index."
        }
    }
}

public enum AddonURL {
    // Escape a single path value, including /, ?, &, =, + and Unicode.
    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }
    public static func http(_ input: String) throws -> URL {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: input), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.host?.isEmpty == false, c.user == nil, c.password == nil, let url = c.url else { throw AddonError.invalidURL }
        return url
    }
    public static func manifest(_ input: String) throws -> URL {
        var input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased().hasPrefix("stremio://") { input = "https://" + input.dropFirst(10) }
        let url = try http(input)
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw AddonError.invalidURL }
        c.fragment = nil
        if !c.path.hasSuffix("/manifest.json") {
            c.percentEncodedPath = c.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .isEmpty ? "/manifest.json" : c.percentEncodedPath.trimmingSuffix("/") + "/manifest.json"
        }
        guard let result = c.url else { throw AddonError.invalidURL }
        return result
    }
    public static func resource(manifest: URL, resource: String, type: String, id: String, extras: [String: String] = [:]) throws -> URL {
        guard var c = URLComponents(url: manifest, resolvingAgainstBaseURL: false), c.path.hasSuffix("/manifest.json") else { throw AddonError.invalidURL }
        c.fragment = nil
        let base = String(c.percentEncodedPath.dropLast("/manifest.json".count))
        let extra = extras.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&")
        c.percentEncodedPath = base + "/" + [resource, type, id].map(encode).joined(separator: "/") + (extra.isEmpty ? "" : "/" + extra) + ".json"
        guard let url = c.url else { throw AddonError.invalidURL }
        return url
    }
    public static func configure(_ manifest: URL) -> URL? {
        guard var c = URLComponents(url: manifest, resolvingAgainstBaseURL: false), c.path.hasSuffix("/manifest.json") else { return nil }
        c.percentEncodedPath = String(c.percentEncodedPath.dropLast("manifest.json".count)) + "configure"
        return c.url
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String { hasSuffix(suffix) ? String(dropLast(suffix.count)) : self }
}

public final class AddonClient: @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 40
            config.httpCookieStorage = nil
            self.session = URLSession(configuration: config)
        }
    }
    public func data(from url: URL) async throws -> Data {
        do {
            _ = try AddonURL.http(url.absoluteString)
            var request = URLRequest(url: url)
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw AddonError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw AddonError.http(response.statusCode) }
            guard data.count <= 12_000_000 else { throw AddonError.invalidResponse }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as AddonError { throw error }
        catch { throw AddonError.network }
    }
    public func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await data(from: url)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AddonError.invalidResponse }
    }
    public func install(_ input: String) async throws -> InstalledAddon {
        let url = try AddonURL.manifest(input)
        let manifest: AddonManifest
        do { manifest = try await fetch(AddonManifest.self, from: url) }
        catch AddonError.invalidResponse { throw AddonError.invalidManifest }
        guard !manifest.id.isEmpty, !manifest.name.isEmpty, !manifest.version.isEmpty, !manifest.resources.isEmpty else { throw AddonError.invalidManifest }
        guard manifest.behaviorHints?.configurationRequired != true else { throw AddonError.configurationRequired }
        return InstalledAddon(manifestURL: url, manifest: manifest)
    }
    public func catalog(_ addon: InstalledAddon, _ catalog: AddonCatalog, extras: [String: String] = [:]) async throws -> [MediaItem] {
        let url = try AddonURL.resource(manifest: addon.manifestURL, resource: "catalog", type: catalog.type, id: catalog.id, extras: extras)
        return try await fetch(CatalogResponse.self, from: url).metas
    }
    public func meta(_ addon: InstalledAddon, item: MediaItem) async throws -> MediaItem? {
        let url = try AddonURL.resource(manifest: addon.manifestURL, resource: "meta", type: item.type, id: item.id)
        return try await fetch(MetaResponse.self, from: url).meta
    }
    public func streams(_ addon: InstalledAddon, type: String, videoID: String) async throws -> [StreamSource] {
        let url = try AddonURL.resource(manifest: addon.manifestURL, resource: "stream", type: type, id: videoID)
        return try await fetch(StreamResponse.self, from: url).streams
    }
    public func subtitles(_ addon: InstalledAddon, type: String, videoID: String, stream: StreamSource) async throws -> [SubtitleSource] {
        var extras: [String: String] = [:]
        if let hash = stream.behaviorHints?.videoHash { extras["videoHash"] = hash }
        if let size = stream.behaviorHints?.videoSize { extras["videoSize"] = String(size) }
        if let filename = stream.behaviorHints?.filename { extras["filename"] = filename }
        let url = try AddonURL.resource(manifest: addon.manifestURL, resource: "subtitles", type: type,
            id: videoID, extras: extras)
        return try await fetch(SubtitleResponse.self, from: url).subtitles
    }
}

public enum PlaybackDestination: Equatable { case native(URL), external(URL) }

public enum StreamResolver {
    public static func resolve(_ stream: StreamSource, server: String) throws -> PlaybackDestination {
        if let external = stream.externalUrl { return .external(try AddonURL.http(external)) }
        if let ytID = stream.ytId {
            return .external(try AddonURL.http("https://www.youtube.com/watch?v=" + AddonURL.encode(ytID)))
        }
        if let raw = stream.url {
            let url = try AddonURL.http(raw)
            guard let headers = stream.behaviorHints?.proxyHeaders,
                  !(headers.request ?? [:]).isEmpty || !(headers.response ?? [:]).isEmpty else { return .native(url) }
            guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AddonError.serverRequired }
            let base = try AddonURL.http(server)
            guard var proxy = URLComponents(url: base, resolvingAgainstBaseURL: false),
                  var origin = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw AddonError.invalidURL }
            origin.path = ""; origin.query = nil; origin.fragment = nil
            var parameters = ["d=" + AddonURL.encode(origin.string ?? "")]
            parameters += (headers.request ?? [:]).sorted { $0.key < $1.key }.map { "h=" + AddonURL.encode($0.key + ":" + $0.value) }
            parameters += (headers.response ?? [:]).sorted { $0.key < $1.key }.map { "r=" + AddonURL.encode($0.key + ":" + $0.value) }
            let source = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            proxy.percentEncodedPath = proxy.percentEncodedPath.trimmingSuffix("/") + "/proxy/" + parameters.joined(separator: "&") + source.percentEncodedPath
            proxy.percentEncodedQuery = source.percentEncodedQuery
            proxy.fragment = nil
            guard let result = proxy.url else { throw AddonError.invalidURL }
            return .native(result)
        }
        if let hash = stream.infoHash {
            guard hash.count == 40, hash.allSatisfy({ $0.isHexDigit }), stream.fileIdx == nil || stream.fileIdx! >= 0 else { throw AddonError.invalidTorrent }
            guard !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AddonError.serverRequired }
            let base = try AddonURL.http(server)
            guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw AddonError.invalidURL }
            c.percentEncodedPath = c.percentEncodedPath.trimmingSuffix("/") + "/\(hash.lowercased())/\(stream.fileIdx ?? -1)"
            let trackers = (stream.sources ?? []).filter { $0.hasPrefix("tracker:") }.map { URLQueryItem(name: "tr", value: String($0.dropFirst(8))) }
            c.queryItems = (c.queryItems ?? []) + trackers
            c.fragment = nil
            guard let url = c.url else { throw AddonError.invalidURL }
            return .native(url)
        }
        throw AddonError.unsupportedStream
    }
}
