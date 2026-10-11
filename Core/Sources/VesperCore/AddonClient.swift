import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AddonError: LocalizedError, Equatable {
    case invalidURL, invalidManifest, configurationRequired, http(Int), invalidResponse, network, unsupportedStream
    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid HTTP or HTTPS URL."
        case .invalidManifest: "This endpoint did not return a valid add-on manifest."
        case .configurationRequired: "Configure this add-on on its website, then paste the generated manifest URL."
        case .http(let status): "The add-on returned HTTP \(status). Try again or check its configuration."
        case .invalidResponse: "The add-on returned an unreadable response."
        case .network: "Couldn’t connect. Check your connection and the add-on address."
        case .unsupportedStream: "This source can’t be opened in an external player. Choose an HTTP video source or an external link."
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
    private let transport: HTTPTransport
    private let cache: ResponseCache?
    private let limiter = RequestLimiter()
    private let metadataRequests = SharedRequestPool<Data>()
    public init(session: URLSession? = nil, cache: ResponseCache? = nil, retryPolicy: RetryPolicy = RetryPolicy()) {
        if let session { self.session = session } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 40
            config.httpCookieStorage = nil
            config.httpMaximumConnectionsPerHost = 4
            self.session = URLSession(configuration: config)
        }
        self.cache = cache
        transport = HTTPTransport(session: self.session, policy: retryPolicy, requestTimeout: 25)
    }
    public func data(from url: URL, operation: NetworkOperation = .metadata) async throws -> Data {
        do {
            _ = try AddonURL.http(url.absoluteString)
            var request = URLRequest(url: url)
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            let transport = transport, boundedRequest = request
            let fetch: @Sendable () async throws -> Data = { [limiter] in
                let (data, response) = try await limiter.run { try await transport.data(for: boundedRequest, operation: operation) }
                try Task.checkCancellation()
                guard (200..<300).contains(response.statusCode) else { throw AddonError.http(response.statusCode) }
                guard data.count <= 12_000_000 else { throw AddonError.invalidResponse }
                return data
            }
            let data: Data
            if operation == .catalog || operation == .metadata {
                data = try await metadataRequests.value(for: url.absoluteString, operation: fetch)
            } else { data = try await fetch() }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as AddonError { throw error }
        catch { throw AddonError.network }
    }
    public func fetch<T: Decodable>(_ type: T.Type, from url: URL, operation: NetworkOperation = .metadata) async throws -> T {
        let data = try await data(from: url, operation: operation)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AddonError.invalidResponse }
    }
    public func install(_ input: String) async throws -> InstalledAddon {
        let url = try AddonURL.manifest(input)
        let manifest: AddonManifest
        do { manifest = try await fetch(AddonManifest.self, from: url, operation: .manifest) }
        catch AddonError.invalidResponse { throw AddonError.invalidManifest }
        guard !manifest.id.isEmpty, !manifest.name.isEmpty, !manifest.version.isEmpty, !manifest.resources.isEmpty else { throw AddonError.invalidManifest }
        guard manifest.behaviorHints?.configurationRequired != true else { throw AddonError.configurationRequired }
        return InstalledAddon(manifestURL: url, manifest: manifest)
    }
    public func catalog(_ addon: InstalledAddon, _ catalog: AddonCatalog, extras: [String: String] = [:], refresh: Bool = false) async throws -> [MediaItem] {
        let url = try AddonURL.resource(manifest: addon.manifestURL, resource: "catalog", type: catalog.type, id: catalog.id, extras: extras)
        let key = try MetadataCacheKey.addonCatalog(addon, catalog, extras: extras)
        if !refresh, let cache, let cached = await cache.value([MediaItem].self, key: key, ttl: 300) {
            if !cached.isFresh {
                await cache.refresh(key: key) { [self] in _ = try await self.catalog(addon, catalog, extras: extras, refresh: true) }
            }
            return cached.value
        }
        let token = await cache?.token()
        let items = try await fetch(CatalogResponse.self, from: url, operation: .catalog).metas
        try Task.checkCancellation()
        // Stream links expire and must always be fetched from their provider on demand.
        let compact = items.map { item -> MediaItem in var value = item; value.videos = nil; return value }
        await cache?.save(compact, key: key, token: token)
        return items
    }
    public func meta(_ addon: InstalledAddon, item: MediaItem) async throws -> MediaItem? {
        let url = try AddonURL.resource(manifest: addon.manifestURL, resource: "meta", type: item.type, id: item.id)
        return try await fetch(MetaResponse.self, from: url).meta
    }
    public func streams(_ addon: InstalledAddon, type: String, videoID: String) async throws -> [StreamSource] {
        let url = try AddonURL.resource(manifest: addon.manifestURL, resource: "stream", type: type, id: videoID)
        return try await fetch(StreamResponse.self, from: url, operation: .streams).streams
    }

}

public enum PlaybackDestination: Equatable { case native(URL), external(URL) }

public enum StreamResolver {
    public static func resolve(_ stream: StreamSource) throws -> PlaybackDestination {
        if let external = stream.externalUrl { return .external(try AddonURL.http(external)) }
        if let ytID = stream.ytId {
            return .external(try AddonURL.http("https://www.youtube.com/watch?v=" + AddonURL.encode(ytID)))
        }
        if let raw = stream.url {
            let url = try AddonURL.http(raw)
            if let headers = stream.behaviorHints?.proxyHeaders,
               !(headers.request ?? [:]).isEmpty || !(headers.response ?? [:]).isEmpty {
                throw AddonError.unsupportedStream
            }
            return .native(url)
        }
        throw AddonError.unsupportedStream
    }
}
