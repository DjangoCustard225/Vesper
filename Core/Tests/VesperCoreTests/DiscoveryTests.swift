import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DiscoveryTests: XCTestCase {
    private let key = String(repeating: "a", count: 32)
    private let config = #"{"images":{"secure_base_url":"https://image.tmdb.org/t/p/","profile_sizes":["w185"],"poster_sizes":["w500"],"backdrop_sizes":["w1280"],"still_sizes":["w92","w185","w300","original"]}}"#
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> TMDBClient {
        let config = config
        FixtureURLProtocol.handler = { request in
            if request.url!.path == "/3/configuration" { return (200, Data(config.utf8)) }
            return try handler(request)
        }
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [FixtureURLProtocol.self]
        return TMDBClient(session: URLSession(configuration: session))
    }
    override func tearDown() { FixtureURLProtocol.handler = nil; super.tearDown() }
    private func media(_ type: String = "series") throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: Data("""
        {"id":"tmdb:\(type == "series" ? "tv" : "movie"):42","type":"\(type)","name":"Title"}
        """.utf8))
    }
    func testCatalogsUseSeparateMovieAndTVEndpoints() async throws {
        let client = client { request in
            let isTV = request.url!.path.contains("/tv/")
            XCTAssertTrue(["/3/movie/popular", "/3/tv/popular", "/3/movie/top_rated", "/3/tv/top_rated"].contains(request.url!.path))
            let json = """
            {"page":2,"total_pages":3,"results":[{"id":42,"\(isTV ? "name" : "title")":"Title","overview":"Synopsis","poster_path":"/p.jpg","backdrop_path":"/b.jpg","release_date":"2026-01-01","first_air_date":"2025-01-01","vote_average":8.5,"vote_count":10}]}
            """
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value, "2")
            return (200, Data(json.utf8))
        }
        for catalog in TMDBCatalog.allCases {
            let result = try await client.catalog(catalog, page: 2, credential: key)
            XCTAssertTrue(result.hasMore)
            XCTAssertEqual(result.items.count, 1)
            XCTAssertEqual(result.items[0].id, "tmdb:\(catalog.mediaType):42")
            XCTAssertEqual(result.items[0].background, "https://image.tmdb.org/t/p/w1280/b.jpg")
            XCTAssertEqual(result.items[0].tmdbRating, 8.5)
            XCTAssertNil(result.items[0].imdbRating)
        }
    }
    func testRecommendationsUseMovieAndTVEndpointsAndKeepProviderOrder() async throws {
        let api = client { request in
            let isTV = request.url!.path == "/3/tv/42/recommendations"
            XCTAssertTrue(isTV || request.url!.path == "/3/movie/42/recommendations")
            return (200, Data("""
            {"page":1,"total_pages":2,"results":[{"id":7,"\(isTV ? "name" : "title")":"First","poster_path":"/first.jpg"},{"id":8,"\(isTV ? "name" : "title")":"Second","poster_path":"/second.jpg"}]}
            """.utf8))
        }
        for type in ["movie", "tv"] {
            let result = try await api.recommendations(tmdbID: 42, mediaType: type, credential: key)
            XCTAssertEqual(result.items.map(\.id), ["tmdb:\(type):7", "tmdb:\(type):8"])
            XCTAssertEqual(result.items.map(\.type), Array(repeating: type == "tv" ? "series" : "movie", count: 2))
            XCTAssertEqual(result.items.first?.poster, "https://image.tmdb.org/t/p/w500/first.jpg")
            XCTAssertTrue(result.hasMore)
        }
    }

    func testRecommendationsExcludeCurrentTitleDuplicatesAdultAndMissingArtwork() async throws {
        let api = client { _ in
            (200, Data(#"{"page":1,"total_pages":1,"results":[{"id":42,"title":"Current","poster_path":"/current.jpg"},{"id":7,"title":"Keep","poster_path":"/keep.jpg"},{"id":7,"title":"Duplicate","poster_path":"/duplicate.jpg"},{"id":8,"title":"Adult","poster_path":"/adult.jpg","adult":true},{"id":9,"title":"No image"},{"id":10,"title":"Unsafe image","poster_path":"/../bad.jpg"}]}"#.utf8))
        }
        let result = try await api.recommendations(tmdbID: 42, mediaType: "movie", credential: key)
        XCTAssertEqual(result.items.map(\.id), ["tmdb:movie:7"])
    }

    func testRecommendationsReuseCacheAndRemainSeparateForDifferentTitles() async throws {
        let calls = LockedRequestCounter()
        let api = client { _ in
            calls.increment()
            return (200, Data(#"{"page":1,"total_pages":1,"results":[{"id":7,"name":"Show","poster_path":"/show.jpg"}]}"#.utf8))
        }
        _ = try await api.recommendations(tmdbID: 42, mediaType: "tv", credential: key)
        _ = try await api.recommendations(tmdbID: 42, mediaType: "tv", credential: key)
        XCTAssertEqual(calls.value, 1)
        _ = try await api.recommendations(tmdbID: 99, mediaType: "tv", credential: key)
        XCTAssertEqual(calls.value, 2)
    }

    func testUnsupportedRecommendationRequestsDoNotContactTMDB() async throws {
        let api = client { _ in XCTFail("Invalid recommendations request reached network"); return (500, Data()) }
        for (id, type) in [(0, "movie"), (42, "series"), (42, "person")] {
            do { _ = try await api.recommendations(tmdbID: id, mediaType: type, credential: key); XCTFail("Expected invalid request") }
            catch { XCTAssertEqual(error as? TMDBError, .invalidResponse) }
        }
    }

    func testEmptyRecommendationsReturnNoUnrelatedFallbackTitles() async throws {
        let api = client { _ in (200, Data(#"{"page":1,"total_pages":0,"results":[]}"#.utf8)) }
        let result = try await api.recommendations(tmdbID: 42, mediaType: "movie", credential: key)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertFalse(result.hasMore)
    }
    func testSearchEscapesQueryAndExcludesPeopleAdultAndDuplicateResults() async throws {
        let term = "雪 & Star + Wars"
        let client = client { request in
            XCTAssertEqual(request.url!.path, "/3/search/multi")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "query" }?.value, term)
            XCTAssertTrue(request.url!.absoluteString.contains("%2B"))
            XCTAssertEqual(query.first { $0.name == "include_adult" }?.value, "false")
            return (200, Data(#"{"page":1,"total_pages":1,"results":[{"id":1,"media_type":"movie","title":"Movie"},{"id":1,"media_type":"movie","title":"Duplicate"},{"id":1,"media_type":"tv","name":"Series"},{"id":9,"media_type":"person","name":"Actor"},{"id":8,"media_type":"movie","title":"Excluded","adult":true},{"id":-1,"media_type":"movie","title":"Bad ID"}]}"#.utf8))
        }
        let result = try await client.search(term, credential: key)
        XCTAssertEqual(result.items.map(\.id), ["tmdb:movie:1", "tmdb:tv:1"])
        XCTAssertFalse(result.hasMore)
    }
    func testListingRejectsWrongPageAndCapsPagination() async throws {
        let client = client { _ in (200, Data(#"{"page":1,"total_pages":900,"results":[]}"#.utf8)) }
        let result = try await client.catalog(.popularMovies, credential: key)
        XCTAssertEqual(result.totalPages, 500)
        do { _ = try await client.catalog(.popularMovies, page: 2, credential: key); XCTFail("Wrong page accepted") }
        catch { XCTAssertEqual(error as? TMDBError, .invalidResponse) }
        do { _ = try await client.catalog(.popularMovies, page: 501, credential: key); XCTFail("Invalid page accepted") }
        catch { XCTAssertEqual(error as? TMDBError, .invalidResponse) }
    }
    func testIMDbMappingPreservesLibraryIdentityAndLoadsEpisodeStreamIDs() async throws {
        let client = client { request in
            if request.url!.path == "/3/tv/42" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "append_to_response" }?.value, "aggregate_credits,external_ids,images")
                return (200, Data(#"{"id":42,"external_ids":{"imdb_id":"tt123"},"seasons":[{"season_number":2,"episode_count":10},{"season_number":0,"episode_count":1},{"season_number":1,"episode_count":8},{"season_number":3,"episode_count":0}]}"#.utf8))
            }
            XCTAssertEqual(request.url!.path, "/3/tv/42/season/2")
            return (200, Data(#"{"season_number":2,"episodes":[{"name":"Second","season_number":2,"episode_number":2},{"name":"First","season_number":2,"episode_number":1,"still_path":"/e.jpg"},{"name":"Duplicate","season_number":2,"episode_number":1},{"name":"Wrong season","season_number":1,"episode_number":3}]}"#.utf8))
        }
        let original = try media()
        let response = try await client.enrichment(for: original, credential: key)
        let details = try XCTUnwrap(response)
        XCTAssertEqual(details.seasons, [0, 1, 2])
        let enriched = details.applying(to: original)
        XCTAssertEqual(enriched.key, original.key)
        XCTAssertEqual(enriched.playbackID, "tt123")
        let episodes = try await client.episodes(for: enriched, tmdbID: 42, season: 2, credential: key)
        XCTAssertEqual(episodes.map(\.id), ["tt123:2:1", "tt123:2:2"])
        XCTAssertEqual(episodes[0].thumbnail, "https://image.tmdb.org/t/p/original/e.jpg")
        XCTAssertNil(episodes[0].streams)
    }
    func testMissingIMDbDoesNotInventStreamID() async throws {
        let client = client { _ in (200, Data(#"{"id":42,"external_ids":{"imdb_id":"wrong:123"}}"#.utf8)) }
        let original = try media("movie")
        let response = try await client.enrichment(for: original, credential: key)
        let details = try XCTUnwrap(response)
        XCTAssertNil(details.imdbID)
        XCTAssertEqual(details.applying(to: original).playbackID, "tmdb:movie:42")
    }
    func testSeasonMismatchIsAnError() async throws {
        let client = client { _ in (200, Data(#"{"season_number":1,"episodes":[]}"#.utf8)) }
        do { _ = try await client.episodes(for: media(), tmdbID: 42, season: 2, credential: key); XCTFail("Wrong season accepted") }
        catch { XCTAssertEqual(error as? TMDBError, .invalidResponse) }
    }
    func testEpisodeRuntimeKeepsValidMinutesAndHandlesUnavailableValues() async throws {
        let client = client { _ in
            (200, Data(#"{"season_number":1,"episodes":[{"season_number":1,"episode_number":1,"runtime":31},{"season_number":1,"episode_number":2,"runtime":0},{"season_number":1,"episode_number":3,"runtime":-5},{"season_number":1,"episode_number":4,"runtime":null},{"season_number":1,"episode_number":5}]}"#.utf8))
        }
        let episodes = try await client.episodes(for: media(), tmdbID: 42, season: 1, credential: key)
        XCTAssertEqual(episodes.map(\.runtimeMinutes), [31, nil, nil, nil, nil])
        let legacy = try JSONDecoder().decode(Episode.self, from: Data(#"{"id":"tt123:1:1","season":1,"episode":1}"#.utf8))
        XCTAssertNil(legacy.runtimeMinutes)
        let roundTrip = try JSONDecoder().decode(Episode.self, from: JSONEncoder().encode(episodes[0]))
        XCTAssertEqual(roundTrip.runtimeMinutes, 31)
        XCTAssertEqual(episodes[0].id, "tmdb:tv:42:1:1")
    }
    func testEpisodeArtworkUsesLargestWidthWhenOriginalIsUnavailable() throws {
        let data = Data(config.replacingOccurrences(of: #"["w92","w185","w300","original"]"#, with: #"["w300","w1280","w92","w185"]"#).utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: data)
        XCTAssertEqual(configuration.episodeImage("/episode.jpg"), "https://image.tmdb.org/t/p/w1280/episode.jpg")
        XCTAssertNil(configuration.episodeImage("/../private.jpg"))
        XCTAssertNil(configuration.episodeImage(nil))
    }
    func testEpisodeArtworkUsesBackdropSizesForOlderConfigurations() throws {
        let data = Data(config.replacingOccurrences(of: #","still_sizes":["w92","w185","w300","original"]"#, with: "").utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: data)
        XCTAssertEqual(configuration.episodeImage("/episode.jpg"), "https://image.tmdb.org/t/p/w1280/episode.jpg")
    }
    func testOlderLibraryItemsRemainDecodable() throws {
        let item = try media("movie")
        XCTAssertNil(item.imdbID); XCTAssertNil(item.tmdbRating)
        XCTAssertEqual(item.playbackID, item.id)
        let roundTrip = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(roundTrip, item)
    }
    func testConcurrentCatalogsShareOneConfigurationRequest() async throws {
        let calls = LockedRequestCounter()
        let config = config
        FixtureURLProtocol.handler = { request in
            if request.url!.path == "/3/configuration" {
                calls.increment(); Thread.sleep(forTimeInterval: 0.03)
                return (200, Data(config.utf8))
            }
            return (200, Data(#"{"page":1,"total_pages":1,"results":[]}"#.utf8))
        }
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [FixtureURLProtocol.self]
        let client = TMDBClient(session: URLSession(configuration: session))
        async let movies = client.catalog(.popularMovies, credential: key)
        async let series = client.catalog(.popularSeries, credential: key)
        async let top = client.catalog(.topRatedMovies, credential: key)
        _ = try await (movies, series, top)
        XCTAssertEqual(calls.value, 1)
    }
    func testTMDBTitlesRecognizeExistingIMDbLibraryAndHistoryEntries() throws {
        var current = try media("movie")
        current.imdbID = "tt123"
        let old = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"id":"tt123","type":"movie","name":"Previously saved"}"#.utf8))
        let differentType = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"id":"tt123","type":"series","name":"Other type"}"#.utf8))
        XCTAssertTrue(current.isSameTitle(as: old))
        XCTAssertTrue(old.isSameTitle(as: current))
        XCTAssertFalse(current.isSameTitle(as: differentType))
        XCTAssertEqual(current.key, "movie:tmdb:movie:42")
    }

    func testConcurrentAndRevisitedCatalogsUseOneDownloadPerPage() async throws {
        let calls = LockedRequestCounter()
        let api = client { request in
            calls.increment(); Thread.sleep(forTimeInterval: 0.03)
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!
            return (200, Data("{\"page\":\(page),\"total_pages\":3,\"results\":[{\"id\":42,\"title\":\"Movie\",\"poster_path\":\"/p.jpg\"}]}".utf8))
        }
        async let first = api.catalog(.popularMovies, credential: key)
        async let second = api.catalog(.popularMovies, credential: key)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.items, b.items)
        _ = try await api.catalog(.popularMovies, credential: key)
        XCTAssertEqual(calls.value, 1)
        let next = try await api.catalog(.popularMovies, page: 2, credential: key)
        XCTAssertEqual(next.page, 2)
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(a.items.first?.poster, "https://image.tmdb.org/t/p/w500/p.jpg")
    }

    func testSeasonCachePreservesEachCallersPlaybackIdentityAndOriginalArtwork() async throws {
        let calls = LockedRequestCounter()
        let api = client { _ in
            calls.increment(); Thread.sleep(forTimeInterval: 0.03)
            return (200, Data(#"{"season_number":1,"episodes":[{"season_number":1,"episode_number":1,"still_path":"/episode.jpg"}]}"#.utf8))
        }
        let original = try media()
        var mapped = original; mapped.imdbID = "tt123"
        async let first = api.episodes(for: original, tmdbID: 42, season: 1, credential: key)
        async let second = api.episodes(for: mapped, tmdbID: 42, season: 1, credential: key)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.first?.id, "tmdb:tv:42:1:1")
        XCTAssertEqual(b.first?.id, "tt123:1:1")
        XCTAssertEqual(b.first?.thumbnail, "https://image.tmdb.org/t/p/original/episode.jpg")
        _ = try await api.episodes(for: mapped, tmdbID: 42, season: 1, credential: key)
        XCTAssertEqual(calls.value, 1)
    }

    func testCatalogAndSeasonCachesClearWhenCredentialChanges() async throws {
        let calls = LockedRequestCounter()
        let api = client { request in
            calls.increment()
            return (200, Data((request.url!.path.contains("/season/")
                ? #"{"season_number":1,"episodes":[]}"#
                : #"{"page":1,"total_pages":1,"results":[]}"#).utf8))
        }
        let original = try media()
        for credential in [key, String(repeating: "b", count: 32)] {
            _ = try await api.catalog(.popularMovies, credential: credential)
            _ = try await api.episodes(for: original, tmdbID: 42, season: 1, credential: credential)
        }
        XCTAssertEqual(calls.value, 4)
    }

    func testInvalidSeasonResponseCanRetryImmediately() async throws {
        let calls = LockedRequestCounter()
        let api = client { _ in
            calls.increment()
            return (200, Data((calls.value == 1
                ? #"{"season_number":2,"episodes":[]}"#
                : #"{"season_number":1,"episodes":[]}"#).utf8))
        }
        let original = try media()
        do { _ = try await api.episodes(for: original, tmdbID: 42, season: 1, credential: key); XCTFail("Expected invalid season") }
        catch { XCTAssertEqual(error as? TMDBError, .invalidResponse) }
        _ = try await api.episodes(for: original, tmdbID: 42, season: 1, credential: key)
        XCTAssertEqual(calls.value, 2)
    }

    func testColdCatalogFetchDoesNotWaitForImageConfiguration() async throws {
        let listingStarted = DispatchSemaphore(value: 0)
        let config = config
        FixtureURLProtocol.handler = { request in
            if request.url!.path == "/3/configuration" {
                XCTAssertEqual(listingStarted.wait(timeout: .now() + 2), .success)
                return (200, Data(config.utf8))
            }
            listingStarted.signal()
            return (200, Data(#"{"page":1,"total_pages":1,"results":[]}"#.utf8))
        }
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ConcurrentTMDBFixtureURLProtocol.self]
        let api = TMDBClient(session: URLSession(configuration: session))
        _ = try await api.catalog(.popularMovies, credential: key)
    }
}

final class ConcurrentTMDBFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().async {
            do {
                let (status, data) = try FixtureURLProtocol.handler!(self.request)
                let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data)
                self.client?.urlProtocolDidFinishLoading(self)
            } catch { self.client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { }
}
