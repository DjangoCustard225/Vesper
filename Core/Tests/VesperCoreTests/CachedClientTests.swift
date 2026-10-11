import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CachedClientTests: XCTestCase {
    func testConcurrentAddonMetadataCallsShareBytesButStreamsRemainFresh() async throws {
        let calls = LockedRequestCounter()
        FixtureURLProtocol.handler = { _ in
            calls.increment(); Thread.sleep(forTimeInterval: 0.05)
            return (200, Data("{}".utf8))
        }
        let client = AddonClient(session: session(), retryPolicy: RetryPolicy(attempts: 1))
        let url = URL(string: "https://provider.example/catalog/movie/popular.json")!
        async let one = client.data(from: url, operation: .catalog)
        async let two = client.data(from: url, operation: .catalog)
        let pair = try await (one, two)
        XCTAssertEqual(pair.0, pair.1); XCTAssertEqual(calls.value, 1)
        async let streamOne = client.data(from: url, operation: .streams)
        async let streamTwo = client.data(from: url, operation: .streams)
        _ = try await (streamOne, streamTwo)
        XCTAssertEqual(calls.value, 3)
    }
    private var directory: URL!
    private let key = String(repeating: "a", count: 32)
    private let configuration = #"{"images":{"secure_base_url":"https://image.tmdb.org/t/p/","profile_sizes":["w185"],"poster_sizes":["w500"],"backdrop_sizes":["w1280"],"still_sizes":["original"]}}"#
    override func setUp() { super.setUp(); directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { FixtureURLProtocol.handler = nil; try? FileManager.default.removeItem(at: directory); super.tearDown() }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: config)
    }
    private func fixture(title: String = "Original") {
        let config = configuration
        FixtureURLProtocol.handler = { request in
            switch request.url!.path {
            case "/3/configuration": return (200, Data(config.utf8))
            case "/3/movie/popular": return (200, Data("{\"page\":1,\"total_pages\":1,\"results\":[{\"id\":42,\"title\":\"\(title)\",\"poster_path\":\"/poster.jpg\"}]}".utf8))
            case "/3/movie/42": return (200, Data(#"{"id":42,"overview":"Synopsis","external_ids":{"imdb_id":"tt123"}}"#.utf8))
            case "/3/tv/42/season/1": return (200, Data(#"{"season_number":1,"episodes":[{"season_number":1,"episode_number":1,"name":"Pilot","still_path":"/episode.jpg"}]}"#.utf8))
            default: XCTFail("Unexpected endpoint: \(request.url!.path)"); return (404, Data())
            }
        }
    }
    func testCatalogDetailsAndEpisodesLoadFromDiskAfterClientRestartWithoutNetworking() async throws {
        fixture()
        let api = TMDBClient(session: session(), cache: ResponseCache(directory: directory))
        let movie = MediaItem(id: "tmdb:movie:42", type: "movie", name: "Movie")
        let show = MediaItem(id: "tmdb:tv:42", type: "series", name: "Show")
        let listing = try await api.catalog(.popularMovies, credential: key)
        let details = try await api.enrichment(for: movie, credential: key)
        let episodes = try await api.episodes(for: show, tmdbID: 42, season: 1, credential: key)
        FixtureURLProtocol.handler = { _ in XCTFail("Fresh disk cache should not use network"); throw URLError(.notConnectedToInternet) }
        let restarted = TMDBClient(session: session(), cache: ResponseCache(directory: directory))
        let cachedListing = try await restarted.catalog(.popularMovies, credential: key)
        let cachedDetails = try await restarted.enrichment(for: movie, credential: key)
        let cachedEpisodes = try await restarted.episodes(for: show, tmdbID: 42, season: 1, credential: key)
        XCTAssertEqual(cachedListing.items, listing.items); XCTAssertEqual(cachedDetails, details); XCTAssertEqual(cachedEpisodes, episodes)
    }
    func testStaleCatalogReturnsImmediatelyThenRevalidatesAndPublishesNewData() async throws {
        fixture()
        let cache = ResponseCache(directory: directory)
        let api = TMDBClient(session: session(), cache: cache)
        let listing = try await api.catalog(.popularMovies, credential: key)
        let request = try TMDBClient.request(path: ["movie", "popular"], query: [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "language", value: "en-US")], credential: key)
        let cacheKey = key + ":listing:" + request.url!.absoluteString
        await cache.save(listing, key: cacheKey, now: Date().addingTimeInterval(-301))
        fixture(title: "Updated")
        let updated = expectation(description: "Background refresh published")
        let observer = NotificationCenter.default.addObserver(forName: .vesperMetadataUpdated, object: nil, queue: nil) { notification in
            let update = notification.object as? MetadataUpdate
            XCTAssertEqual(update?.cacheID, MetadataCacheKey.id(cacheKey))
            XCTAssertFalse(update?.cacheID.contains("https") ?? true)
            updated.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let restarted = TMDBClient(session: session(), cache: cache)
        let stale = try await restarted.catalog(.popularMovies, credential: key)
        XCTAssertEqual(stale.items.first?.name, "Original")
        await fulfillment(of: [updated], timeout: 2)
        let fresh = try await restarted.catalog(.popularMovies, credential: key)
        XCTAssertEqual(fresh.items.first?.name, "Updated")
    }
    func testFailedRevalidationDoesNotDeleteCachedCatalog() async throws {
        fixture()
        let cache = ResponseCache(directory: directory), api = TMDBClient(session: session(), cache: ResponseCache(directory: directory))
        let listing = try await api.catalog(.popularMovies, credential: key)
        let request = try TMDBClient.request(path: ["movie", "popular"], query: [URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "language", value: "en-US")], credential: key)
        let cacheKey = key + ":listing:" + request.url!.absoluteString
        await cache.save(listing, key: cacheKey, now: Date().addingTimeInterval(-301))
        let attempted = expectation(description: "Refresh attempted")
        FixtureURLProtocol.handler = { _ in attempted.fulfill(); return (503, Data()) }
        let restarted = TMDBClient(session: session(), cache: cache, retryPolicy: RetryPolicy(attempts: 1))
        let result = try await restarted.catalog(.popularMovies, credential: key)
        XCTAssertEqual(result.items.first?.name, "Original")
        await fulfillment(of: [attempted], timeout: 2)
        let retained = await cache.value(TMDBPage.self, key: cacheKey, ttl: 300)
        XCTAssertEqual(retained?.value.items.first?.name, "Original")
        await restarted.invalidate()
    }
    func testAddonCatalogPersistsWithoutCachingEmbeddedPlaybackURLs() async throws {
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: Data(#"{"id":"test","name":"Test","version":"1","resources":["catalog","stream"],"types":["movie"],"catalogs":[{"id":"popular","type":"movie"}]}"#.utf8))
        let addon = InstalledAddon(manifestURL: URL(string: "https://provider.example/private-configuration/manifest.json")!, manifest: manifest)
        FixtureURLProtocol.handler = { _ in (200, Data(#"{"metas":[{"id":"tt123","type":"movie","name":"Title","videos":[{"id":"tt123","streams":[{"url":"https://video.example/private-stream?signature=secret"}]}]}]}"#.utf8)) }
        let api = AddonClient(session: session(), cache: ResponseCache(directory: directory))
        let first = try await api.catalog(addon, manifest.catalogs[0])
        XCTAssertEqual(first.first?.videos?.first?.streams?.count, 1)
        FixtureURLProtocol.handler = { _ in XCTFail("Catalog should be cached"); throw URLError(.notConnectedToInternet) }
        let cached = try await AddonClient(session: session(), cache: ResponseCache(directory: directory)).catalog(addon, manifest.catalogs[0])
        XCTAssertEqual(cached.first?.id, "tt123"); XCTAssertNil(cached.first?.videos)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let entry = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let payload = Data(base64Encoded: entry["data"] as! String)!
            XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("private-stream"))
        }
    }
    func testIdentityResolutionUsesCorrectMediaTypeAndCachesKnownMappings() async throws {
        let calls = LockedRequestCounter()
        FixtureURLProtocol.handler = { request in
            calls.increment(); XCTAssertEqual(request.url?.path, "/3/find/tt123")
            return (200, Data(#"{"movie_results":[{"id":42}],"tv_results":[{"id":99}]}"#.utf8))
        }
        let api = TMDBClient(session: session(), cache: ResponseCache(directory: directory))
        let movie = try await api.identified(MediaItem(id: "tt123", type: "movie", name: "Title"), credential: key)
        let show = try await api.identified(MediaItem(id: "tt123", type: "series", name: "Title"), credential: key)
        XCTAssertEqual(movie.tmdbID, 42); XCTAssertEqual(show.tmdbID, 99)
        XCTAssertEqual(calls.value, 2)
        FixtureURLProtocol.handler = { _ in XCTFail("Identity should be cached"); throw URLError(.notConnectedToInternet) }
        let cached = try await TMDBClient(session: session(), cache: ResponseCache(directory: directory)).identified(MediaItem(id: "tt123", type: "movie", name: "Title"), credential: key)
        XCTAssertEqual(cached.tmdbID, 42)
        XCTAssertEqual(MediaIdentity.unique([MediaItem(id: "tmdb:movie:42", type: "movie", name: "Title"), cached]).count, 1)
        let reverse = try await api.identified(MediaItem(id: "tmdb:movie:42", type: "movie", name: "Title"), credential: key, resolveUnknown: false)
        XCTAssertEqual(reverse.imdbID, "tt123")
        let unknown = try await api.identified(MediaItem(id: "tt999", type: "movie", name: "Title"), credential: key, resolveUnknown: false)
        XCTAssertNil(unknown.tmdbID)
    }
    func testCredentialChangeCannotReuseAnotherCredentialsPersistentCache() async throws {
        fixture()
        let api = TMDBClient(session: session(), cache: ResponseCache(directory: directory), retryPolicy: RetryPolicy(attempts: 1))
        _ = try await api.catalog(.popularMovies, credential: key)
        FixtureURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await api.catalog(.popularMovies, credential: String(repeating: "b", count: 32)); XCTFail("Other credential reused cached content") }
        catch { XCTAssertEqual(error as? TMDBError, .unauthorized) }
    }
    func testOldCredentialRefreshCannotReplaceCurrentCredential() async throws {
        fixture()
        let api = TMDBClient(session: session(), cache: ResponseCache(directory: directory))
        let newKey = String(repeating: "b", count: 32)
        _ = try await api.catalog(.popularMovies, credential: key)
        _ = try await api.catalog(.popularMovies, credential: newKey)
        FixtureURLProtocol.handler = { _ in XCTFail("Old refresh must not reactivate its credential"); throw URLError(.notConnectedToInternet) }
        do {
            _ = try await api.enrichment(for: MediaItem(id: "tmdb:movie:42", type: "movie", name: "Movie"), credential: key, refresh: true)
            XCTFail("Old detail refresh should be cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            _ = try await api.episodes(for: MediaItem(id: "tmdb:tv:42", type: "series", name: "Show"), tmdbID: 42, season: 1, credential: key, refresh: true)
            XCTFail("Old season refresh should be cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        let current = try await api.catalog(.popularMovies, credential: newKey)
        XCTAssertEqual(current.items.first?.name, "Original")
    }
}
