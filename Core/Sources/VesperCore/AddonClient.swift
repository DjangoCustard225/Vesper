import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class AddonClient: Sendable {
    private let session: URLSession
    private let ownsSession: Bool
    private let transport: HTTPTransport
    private let cache: ResponseCache?
    private let limiter = RequestLimiter()
    private let metadataRequests = SharedRequestPool<Data>()

    public init(
        session: URLSession? = nil, cache: ResponseCache? = nil, retryPolicy: RetryPolicy = RetryPolicy()
    ) {
        ownsSession = session == nil
        if let session {
            self.session = session
        } else {
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

    deinit { if ownsSession { session.invalidateAndCancel() } }

    public func clearCache() async throws {
        await metadataRequests.cancelAll()
        session.configuration.urlCache?.removeAllCachedResponses()
        try await cache?.removeAll()
    }

    public func data(from url: URL, operation: NetworkOperation = .metadata) async throws -> Data {
        do {
            _ = try AddonURL.http(url.absoluteString)
            var request = URLRequest(url: url)
            request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            let transport = transport, boundedRequest = request
            let fetch: @Sendable () async throws -> Data = { [limiter] in
                let (data, response) = try await limiter.run {
                    try await transport.data(for: boundedRequest, operation: operation)
                }
                try Task.checkCancellation()
                guard (200..<300).contains(response.statusCode) else {
                    throw AddonError.http(response.statusCode)
                }
                return data
            }
            let data: Data
            if operation == .catalog || operation == .metadata {
                data = try await metadataRequests.value(for: url.absoluteString, operation: fetch)
            } else {
                data = try await fetch()
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() } catch let error as URLError
            where error.code == .cancelled
        { throw CancellationError() } catch let error as URLError
            where error.code == .dataLengthExceedsMaximum
        { throw AddonError.invalidResponse } catch let error as AddonError { throw error } catch {
            throw AddonError.network
        }
    }

    public func fetch<T: Decodable>(_ type: T.Type, from url: URL, operation: NetworkOperation = .metadata)
        async throws -> T
    {
        let data = try await data(from: url, operation: operation)
        do { return try JSONDecoder().decode(type, from: data) } catch { throw AddonError.invalidResponse }
    }

    public func install(_ input: String) async throws -> InstalledAddon {
        let url = try AddonURL.manifest(input)
        let manifest: AddonManifest
        do {
            manifest = try await fetch(AddonManifest.self, from: url, operation: .manifest)
        } catch AddonError.invalidResponse { throw AddonError.invalidManifest }
        guard !manifest.id.isEmpty, !manifest.name.isEmpty, !manifest.version.isEmpty,
            !manifest.resources.isEmpty
        else { throw AddonError.invalidManifest }
        guard manifest.behaviorHints?.configurationRequired != true else {
            throw AddonError.configurationRequired
        }
        return InstalledAddon(manifestURL: url, manifest: manifest)
    }

    public func catalog(
        _ addon: InstalledAddon, _ catalog: AddonCatalog, extras: [String: String] = [:],
        refresh: Bool = false
    ) async throws -> [MediaItem] {
        let url = try AddonURL.resource(
            manifest: addon.manifestURL, resource: "catalog", type: catalog.type, id: catalog.id,
            extras: extras)
        let key = try MetadataCacheKey.addonCatalog(addon, catalog, extras: extras)
        // Search follows the live add-on catalog path from 0.1.
        let catalogCache = extras["search"] == nil ? cache : nil
        if !refresh, let cache = catalogCache,
            let cached = await cache.value([MediaItem].self, key: key, ttl: 300)
        {
            if !cached.isFresh {
                await cache.refresh(key: key) { [self] in
                    _ = try await self.catalog(addon, catalog, extras: extras, refresh: true)
                }
            }
            return cached.value
        }
        let token = await catalogCache?.token()
        let items = try await fetch(CatalogResponse.self, from: url, operation: .catalog).metas
        try Task.checkCancellation()
        // Stream links expire and must always be fetched from their provider on demand.
        let compact = items.map { item -> MediaItem in
            var value = item
            value.videos = nil
            return value
        }
        await catalogCache?.save(compact, key: key, token: token)
        return items
    }

    public func meta(_ addon: InstalledAddon, item: MediaItem) async throws -> MediaItem? {
        let url = try AddonURL.resource(
            manifest: addon.manifestURL, resource: "meta", type: item.type, id: item.id)
        return try await fetch(MetaResponse.self, from: url).meta
    }

    public func streams(_ addon: InstalledAddon, type: String, videoID: String) async throws -> [StreamSource]
    {
        let url = try AddonURL.resource(
            manifest: addon.manifestURL, resource: "stream", type: type, id: videoID)
        return try await fetch(StreamResponse.self, from: url, operation: .streams).streams
    }

}
