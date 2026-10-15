import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class CacheClearingTests: XCTestCase {
    private let fixture = HTTPFixture()
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testMetadataClearPreservesSiblingFilesAndRejectsOldWrites() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let saved = directory.appendingPathComponent("library.json")
        let personalData = Data("saved library".utf8)
        try personalData.write(to: saved)
        let cache = ResponseCache(directory: directory.appendingPathComponent("Metadata"))
        let oldToken = await cache.token()
        await cache.save("old", key: "title", token: oldToken)
        try await cache.removeAll()
        try await cache.removeAll()  // Clearing an already empty cache is harmless.
        await cache.save("late response", key: "title", token: oldToken)
        let removed = await cache.value(String.self, key: "title", ttl: 300)
        XCTAssertNil(removed)
        XCTAssertEqual(try Data(contentsOf: saved), personalData)
        await cache.save("new", key: "title", token: await cache.token())
        let fresh = await cache.value(String.self, key: "title", ttl: 300)
        XCTAssertEqual(fresh?.value, "new")
    }

    func testAddonClearFetchesFreshCatalogInsteadOfPersistedResponse() async throws {
        let calls = LockedRequestCounter()
        fixture.handler = { _ in
            let number = calls.increment()
            return (
                200,
                Data("{\"metas\":[{\"id\":\"tt123\",\"type\":\"movie\",\"name\":\"Title \(number)\"}]}".utf8)
            )
        }
        let manifest = try JSONDecoder().decode(
            AddonManifest.self,
            from: Data(
                #"{"id":"test","name":"Test","version":"1","resources":["catalog"],"types":["movie"],"catalogs":[{"id":"popular","type":"movie"}]}"#
                    .utf8))
        let addon = InstalledAddon(
            manifestURL: URL(string: "https://provider.example/manifest.json")!, manifest: manifest)
        let cache = ResponseCache(directory: directory)
        let api = AddonClient(session: fixture.session(), cache: cache)
        _ = try await api.catalog(addon, manifest.catalogs[0])
        let cached = try await api.catalog(addon, manifest.catalogs[0])
        XCTAssertEqual(cached.first?.name, "Title 1")
        XCTAssertEqual(calls.value, 1)
        try await api.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let fresh = try await api.catalog(addon, manifest.catalogs[0])
        XCTAssertEqual(fresh.first?.name, "Title 2")
        XCTAssertEqual(calls.value, 2)
    }

    func testAddonClearCancelsMetadataWithoutCancellingStreamRequests() async throws {
        let metadataStarted = expectation(description: "Metadata started")
        let streamStarted = expectation(description: "Stream started")
        let metadataChunks = LockedRequestCounter(), streamChunks = LockedRequestCounter()
        fixture.respond = { request in
            let stream = request.url!.path == "/stream"
            var response = FixtureResponse()
            response.chunks = [Data([1]), Data([2])]
            response.chunkInterval = 0.05
            response.onChunk = {
                if (stream ? streamChunks : metadataChunks).increment() == 1 {
                    (stream ? streamStarted : metadataStarted).fulfill()
                }
            }
            return response
        }
        let api = AddonClient(session: fixture.session(), retryPolicy: RetryPolicy(attempts: 1))
        let metadata = Task {
            try await api.data(from: URL(string: "https://provider.example/catalog")!, operation: .catalog)
        }
        let stream = Task {
            try await api.data(from: URL(string: "https://provider.example/stream")!, operation: .streams)
        }
        await fulfillment(of: [metadataStarted, streamStarted], timeout: 2)
        try await api.clearCache()
        do {
            _ = try await metadata.value
            XCTFail("Old metadata request survived clearing")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let bytes = try await stream.value
        XCTAssertEqual(bytes, Data([1, 2]))
    }

    func testTMDBClearRemovesMemoryAndDiskCachesIncludingSearch() async throws {
        let catalogCalls = LockedRequestCounter(), searchCalls = LockedRequestCounter()
        fixture.handler = { request in
            if request.url!.path == "/3/configuration" {
                return (
                    200,
                    Data(
                        #"{"images":{"secure_base_url":"https://image.tmdb.org/t/p/","profile_sizes":["w185"],"poster_sizes":["w500"],"backdrop_sizes":["w1280"],"still_sizes":["original"]}}"#
                            .utf8)
                )
            }
            let number = (request.url!.path == "/3/search/multi" ? searchCalls : catalogCalls).increment()
            return (
                200,
                Data(
                    "{\"page\":1,\"total_pages\":1,\"results\":[{\"id\":42,\"media_type\":\"movie\",\"title\":\"Title \(number)\"}]}"
                        .utf8)
            )
        }
        let api = TMDBClient(session: fixture.session(), cache: ResponseCache(directory: directory))
        let key = String(repeating: "a", count: 32)
        for _ in 0..<2 {
            _ = try await api.catalog(.popularMovies, credential: key)
            _ = try await api.search("title", credential: key)
        }
        XCTAssertEqual(catalogCalls.value, 1)
        XCTAssertEqual(searchCalls.value, 1)
        try await api.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let catalog = try await api.catalog(.popularMovies, credential: key)
        let search = try await api.search("title", credential: key)
        XCTAssertEqual(catalog.items.first?.name, "Title 2")
        XCTAssertEqual(search.items.first?.name, "Title 2")
        XCTAssertEqual(catalogCalls.value, 2)
        XCTAssertEqual(searchCalls.value, 2)
    }

    func testArtworkClearRemovesRawMemoryAndHTTPResponses() async throws {
        let calls = LockedRequestCounter()
        fixture.handler = { _ in (200, Data([UInt8(calls.increment())])) }
        let originalSession = fixture.session()
        let configuration = originalSession.configuration
        let httpCache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0, diskPath: nil)
        configuration.urlCache = httpCache
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            originalSession.invalidateAndCancel()
        }
        let client = ArtworkDataClient(session: session)
        let url = URL(string: "https://images.example/poster.jpg")!
        _ = try await client.data(for: url)
        _ = try await client.data(for: url)
        XCTAssertEqual(calls.value, 1)
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        httpCache.storeCachedResponse(CachedURLResponse(response: response, data: Data([1])), for: request)
        XCTAssertNotNil(httpCache.cachedResponse(for: request))
        await client.clearCache()
        XCTAssertNil(httpCache.cachedResponse(for: request))
        let fresh = try await client.data(for: url)
        XCTAssertEqual(fresh, Data([2]))
        XCTAssertEqual(calls.value, 2)
    }

    func testArtworkClearCancelsOldDownloadAndNextRequestSucceeds() async throws {
        let started = expectation(description: "Old artwork started")
        let calls = LockedRequestCounter(), chunks = LockedRequestCounter()
        fixture.respond = { _ in
            guard calls.increment() == 1 else { return FixtureResponse(body: Data([9])) }
            var response = FixtureResponse()
            response.chunks = [Data([1]), Data([2])]
            response.chunkInterval = 0.1
            response.onChunk = { if chunks.increment() == 1 { started.fulfill() } }
            return response
        }
        let client = ArtworkDataClient(session: fixture.session())
        let url = URL(string: "https://images.example/poster.jpg")!
        let old = Task { try await client.data(for: url) }
        await fulfillment(of: [started], timeout: 2)
        await client.clearCache()
        do {
            _ = try await old.value
            XCTFail("Old artwork request survived clearing")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let fresh = try await client.data(for: url)
        let cached = try await client.data(for: url)
        XCTAssertEqual(fresh, Data([9]))
        XCTAssertEqual(cached, fresh)
        XCTAssertEqual(calls.value, 2)
    }
}
