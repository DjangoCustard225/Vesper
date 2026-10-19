import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class TVDBRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    @discardableResult func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class TVDBTests: XCTestCase {
    private let fixture = HTTPFixture()
    private let series =
        #"{"id":12,"overview":"Original description","image":"https://artworks.thetvdb.com/poster.jpg","translations":{"overviewTranslations":[{"language":"eng","overview":"English description"}]},"remoteIds":[{"id":"tt123","sourceName":"IMDB"},{"id":"42","sourceName":"TheMovieDB.com"}],"seasons":[{"number":0,"type":{"type":"official"}},{"number":1,"type":{"type":"official"}},{"number":8,"type":{"type":"dvd"}}],"characters":[{"peopleId":7,"personName":"Actor","personImgURL":"https://artworks.thetvdb.com/actor.jpg","peopleType":"Actor","name":"Lead"},{"peopleId":8,"personName":"Hidden","peopleType":"Actor"},{"peopleId":9,"personName":"Crew","personImgURL":"https://artworks.thetvdb.com/crew.jpg","peopleType":"Director"}],"artworks":[{"type":3,"image":"https://artworks.thetvdb.com/background.jpg","language":"eng"}]}"#
    private var credentials: TVDBCredentials {
        try! TVDBCredentials(apiKey: "private-key", pin: "private-pin")
    }
    private var show: MediaItem { MediaItem(id: "tt123", type: "series", name: "Show") }

    private func envelope(_ data: String, next: String? = nil) -> Data {
        Data(
            ("{\"status\":\"success\",\"data\":" + data + ",\"links\":{\"next\":"
                + (next.map { "\"" + $0 + "\"" } ?? "null") + "}}").utf8)
    }

    private func client(cache: ResponseCache? = nil) -> TVDBClient {
        TVDBClient(session: fixture.session(), cache: cache, retryPolicy: RetryPolicy(attempts: 1))
    }

    private func installSeries() {
        let series = series
        fixture.handler = { request in
            XCTAssertEqual(request.url?.host, "api4.thetvdb.com")
            switch request.url!.path {
            case "/v4/login": return (200, self.envelope(#"{"token":"token"}"#))
            case "/v4/search/remoteid/tt123":
                return (200, self.envelope(#"[{"series":{"id":12}},{"movie":{"id":99}}]"#))
            case "/v4/series/12/extended": return (200, self.envelope(series))
            case "/v4/artwork/types":
                return (200, self.envelope(#"[{"id":3,"name":"Background","recordType":"series"}]"#))
            default: XCTFail("Unexpected TVDB endpoint"); return (404, Data())
            }
        }
    }

    func testCredentialsAndLoginOmitAbsentPINAndCoalesce() async throws {
        XCTAssertThrowsError(try TVDBCredentials(apiKey: " "))
        XCTAssertThrowsError(try TVDBCredentials(apiKey: "a\nb"))
        XCTAssertNil(try TVDBCredentials(apiKey: " key ", pin: " ").pin)
        let calls = TVDBRequestCounter()
        fixture.respond = { request in
            calls.increment()
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.url?.query)
            let body =
                try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: String]
            XCTAssertEqual(body, ["apikey": "key"])
            var response = FixtureResponse(body: self.envelope(#"{"token":"session"}"#))
            response.chunkInterval = 0.03
            return response
        }
        let api = client(), auth = try TVDBCredentials(apiKey: "key")
        async let first: Void = api.validate(credentials: auth)
        async let second: Void = api.validate(credentials: auth)
        _ = try await (first, second)
        XCTAssertEqual(calls.value, 1)
    }

    func testPINAndUnauthorizedLogin() async throws {
        fixture.handler = { request in
            let body =
                try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: String]
            XCTAssertEqual(body["pin"], "private-pin")
            return (401, Data())
        }
        do { try await client().validate(credentials: credentials); XCTFail("Expected rejection") } catch {
            XCTAssertEqual(error as? TVDBError, .unauthorized)
        }
    }

    func testSeriesEnrichmentPreservesPlaybackAndProviderIDs() async throws {
        installSeries()
        let result = try await client().enrichment(for: show, credentials: credentials)
        let details = try XCTUnwrap(result)
        XCTAssertEqual(details.reference.key, "tvdb:12")
        XCTAssertEqual(details.tmdbID, 42)
        XCTAssertEqual(details.seasons, [0, 1])
        XCTAssertEqual(details.overview, "English description")
        XCTAssertEqual(details.backdropURL, "https://artworks.thetvdb.com/background.jpg")
        XCTAssertEqual(details.cast.map(\.name), ["Actor"])
        XCTAssertEqual(details.crew?.first?.jobs, ["Director"])
        XCTAssertEqual(details.cast.first?.reference.key, "tvdb:7")
        XCTAssertNil(details.cast.first?.tmdbID)
        let enriched = details.applying(to: show)
        XCTAssertEqual(enriched.id, show.id)
        XCTAssertEqual(enriched.playbackID, "tt123")
        XCTAssertEqual(enriched.tmdbID, 42)
        XCTAssertEqual(enriched.tvdbID, 12)
        XCTAssertEqual(enriched.name, show.name)
    }

    func testAmbiguousMatchesAndUnsupportedTypesAreNotGuessed() async throws {
        fixture.handler = { request in
            if request.url!.path == "/v4/login" { return (200, self.envelope(#"{"token":"token"}"#)) }
            return (200, self.envelope(#"[{"series":{"id":12}},{"series":{"id":13}}]"#))
        }
        let result = try await client().enrichment(for: show, credentials: credentials)
        XCTAssertNil(result)
        fixture.handler = { _ in
            XCTFail("No name search or movie requests"); return (500, Data())
        }
        let unknown = try await client().enrichment(
            for: MediaItem(id: "custom", type: "series", name: "Show"), credentials: credentials)
        let movie = try await client().enrichment(
            for: MediaItem(id: "tt123", type: "movie", name: "Show"), credentials: credentials)
        XCTAssertNil(unknown)
        XCTAssertNil(movie)
    }

    func testExpiredTokenRenewsOnceAndPermanentAuthorizationStops() async throws {
        let logins = TVDBRequestCounter(), reads = TVDBRequestCounter()
        fixture.handler = { request in
            if request.url!.path == "/v4/login" {
                let n = logins.increment()
                return (200, self.envelope("{\"token\":\"token\(n)\"}"))
            }
            reads.increment()
            return (401, Data())
        }
        do {
            _ = try await client().enrichment(for: show, credentials: credentials);
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? TVDBError, .unauthorized) }
        XCTAssertEqual(logins.value, 2)
        XCTAssertEqual(reads.value, 2)
    }

    func testRenewedTokenResumesMetadata() async throws {
        let logins = TVDBRequestCounter()
        fixture.handler = { request in
            if request.url!.path == "/v4/login" {
                let n = logins.increment()
                return (200, self.envelope("{\"token\":\"token\(n)\"}"))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer token1" { return (401, Data()) }
            return (200, self.envelope("[]"))
        }
        let value = try await client().enrichment(for: show, credentials: credentials)
        XCTAssertNil(value)
        XCTAssertEqual(logins.value, 2)
    }

    func testEpisodePaginationAndIdentityRemainIndependentAcrossCallers() async throws {
        let pages = TVDBRequestCounter()
        fixture.handler = { request in
            if request.url!.path == "/v4/login" { return (200, self.envelope(#"{"token":"token"}"#)) }
            XCTAssertEqual(request.url!.path, "/v4/series/12/episodes/official")
            pages.increment()
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first {
                $0.name == "page"
            }?.value
            if page == "0" {
                return (
                    200,
                    self.envelope(
                        #"{"series":{"id":12},"episodes":[{"id":1,"seriesId":12,"seasonNumber":0,"number":1,"name":"Special"}]}"#,
                        next: "https://untrusted.example/ignored")
                )
            }
            return (
                200,
                self.envelope(
                    #"{"series":{"id":12},"episodes":[{"id":2,"seriesId":12,"seasonNumber":0,"number":2,"name":"Second"}]}"#
                )
            )
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = client(cache: ResponseCache(directory: directory))
        let episodes = try await api.episodes(for: show, id: 12, season: 0, credentials: credentials)
        XCTAssertEqual(episodes.map(\.id), ["tt123:0:1", "tt123:0:2"])
        var custom = show
        custom.videos = [
            Episode(
                id: "provider:custom", title: nil, name: nil, season: 0, episode: 1,
                overview: nil, thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
        ]
        let revisit = try await api.episodes(for: custom, id: 12, season: 0, credentials: credentials)
        XCTAssertEqual(revisit.first?.id, "provider:custom")
        XCTAssertEqual(pages.value, 2)
    }

    func testMismatchedAndRepeatedEpisodePagesAreRejected() async throws {
        for repeated in [false, true] {
            fixture.handler = { request in
                if request.url!.path == "/v4/login" { return (200, self.envelope(#"{"token":"token"}"#)) }
                let season = repeated ? 1 : 2
                return (
                    200,
                    self.envelope(
                        "{\"series\":{\"id\":12},\"episodes\":[{\"id\":1,\"seriesId\":12,\"seasonNumber\":\(season),\"number\":1}]}",
                        next: "next")
                )
            }
            do {
                _ = try await client().episodes(for: show, id: 12, season: 1, credentials: credentials);
                XCTFail("Expected invalid response")
            } catch { XCTAssertEqual(error as? TVDBError, .invalidResponse) }
        }
    }

    func testCacheRestartClearAndCredentialIsolation() async throws {
        installSeries()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ResponseCache(directory: directory)
        _ = try await client(cache: disk).enrichment(for: show, credentials: credentials)
        fixture.handler = { _ in
            XCTFail("Fresh disk details need no network"); return (500, Data())
        }
        let cached = try await client(cache: disk).enrichment(for: show, credentials: credentials)
        XCTAssertEqual(cached?.id, 12)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("private-key"))
            XCTAssertFalse(text.contains("private-pin"))
            XCTAssertFalse(text.contains("\"token\""))
        }
        XCTAssertNotEqual(
            TVDBClient.detailsKey(show, credentials: credentials),
            TVDBClient.detailsKey(show, credentials: try TVDBCredentials(apiKey: "other")))
        let api = client(cache: disk)
        try await api.clearCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFallbackKeepsSuccessfulPrimaryAndDoesNotSwallowCancellation() async throws {
        let original = try JSONDecoder().decode(TVDBSeries.self, from: Data(series.utf8)).enrichment(
            artworkTypes: [])
        let result = try await MetadataResolver.enrichment(
            primary: { original }, fallback: { throw TMDBError.unavailable })
        XCTAssertEqual(result, original)
        let fallback = try await MetadataResolver.enrichment(
            primary: { throw TVDBError.unauthorized }, fallback: { original })
        XCTAssertEqual(fallback, original)
        do {
            _ = try await MetadataResolver.enrichment(
                primary: { throw CancellationError() },
                fallback: {
                    XCTFail("Cancellation must not start fallback"); return original
                })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLegacyModelsDecodeAndTVDBAliasesDoNotCollideWithTMDB() throws {
        let value = try JSONDecoder().decode(
            MediaItem.self, from: Data(#"{"id":"tt123","type":"series","name":"Show"}"#.utf8))
        XCTAssertNil(value.tvdbID)
        var tvdb = value
        tvdb.tvdbID = 42
        let tmdb = MediaItem(id: "tmdb:tv:42", type: "series", name: "Different show")
        XCTAssertFalse(tvdb.isSameTitle(as: tmdb))
        let oldPerson = try JSONDecoder().decode(
            CastMember.self, from: Data(#"{"id":7,"name":"Actor"}"#.utf8))
        XCTAssertEqual(oldPerson.reference.key, "tmdb:7")
        XCTAssertEqual(oldPerson.tmdbID, 7)
        let json = try JSONEncoder().encode(tvdb)
        XCTAssertEqual(try JSONDecoder().decode(MediaItem.self, from: json).tvdbID, 42)
    }

    func testInvalidBodiesRateLimitsAndUntrustedArtwork() async throws {
        for status in [200, 429, 503] {
            fixture.handler = { _ in (status, Data("invalid".utf8)) }
            do { try await client().validate(credentials: credentials); XCTFail("Expected error") } catch {
                XCTAssertEqual(
                    error as? TVDBError,
                    status == 200 ? .invalidResponse : (status == 429 ? .rateLimited : .unavailable))
            }
        }
        XCTAssertNil(TVDBImage.url("https://untrusted.example/image.jpg"))
        XCTAssertNil(TVDBImage.url("file:///private/image.jpg"))
        XCTAssertNil(TVDBImage.url("https://artworks.thetvdb.com/logo.svg"))
        XCTAssertEqual(
            TVDBImage.url("/banners/original.jpg"), "https://artworks.thetvdb.com/banners/original.jpg")
    }
    func testInvalidationCancelsPendingWorkAndBorrowedSessionRemainsUsable() async throws {
        let calls = TVDBRequestCounter()
        fixture.respond = { _ in
            calls.increment()
            var response = FixtureResponse(body: self.envelope(#"{"token":"token"}"#))
            response.chunkInterval = 0.2
            return response
        }
        let session = fixture.session()
        let api = TVDBClient(session: session)
        let credentials = credentials
        let task = Task { try await api.validate(credentials: credentials) }
        for _ in 0..<200 {
            if calls.value > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThan(calls.value, 0)
        await api.invalidate()
        do { try await task.value; XCTFail("Expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        fixture.handler = { _ in (200, self.envelope(#"{"token":"fresh"}"#)) }
        try await api.validate(credentials: credentials)
        _ = try await session.data(for: fixture.request(URL(string: "https://api4.thetvdb.com/test")!))
    }

    func testStaleDetailsReturnImmediatelyThenRevalidate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ResponseCache(directory: directory)
        let stale = try JSONDecoder().decode(
            TVDBSeries.self, from: Data(#"{"id":12,"overview":"Stale"}"#.utf8)
        ).enrichment(artworkTypes: [])
        let key = TVDBClient.detailsKey(show, credentials: credentials)
        await disk.save(stale, key: key, now: Date().addingTimeInterval(-7 * 3600))
        installSeries()
        let api = client(cache: disk)
        let first = try await api.enrichment(for: show, credentials: credentials)
        XCTAssertEqual(first?.overview, "Stale")
        var updated: MetadataEnrichment?
        for _ in 0..<200 {
            updated = await disk.value(MetadataEnrichment.self, key: key, ttl: 6 * 3600)?.value
            if updated?.overview == "English description" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(updated?.overview, "English description")
    }

    func testMetadataAndEpisodeFallbackFillsOnlyMissingFields() throws {
        let primary = try JSONDecoder().decode(
            TVDBSeries.self,
            from: Data(
                #"{"id":12,"overview":"TVDB","seasons":[{"number":1,"type":{"type":"official"}}]}"#.utf8)
        ).enrichment(artworkTypes: [])
        var data = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(primary)) as? [String: Any])
        data.removeValue(forKey: "provider")
        data["id"] = 42
        data["overview"] = "TMDB"
        data["posterURL"] = "https://image.tmdb.org/poster.jpg"
        let fallback = try JSONDecoder().decode(
            MetadataEnrichment.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertEqual(fallback.reference.key, "tmdb:42")
        let merged = primary.fillingMissing(from: fallback)
        XCTAssertEqual(merged.overview, "TVDB")
        XCTAssertEqual(merged.posterURL, fallback.posterURL)
        XCTAssertEqual(merged.tmdbID, 42)
        XCTAssertEqual(merged.reference.key, "tvdb:12")
        func episode(_ id: String, number: Int, title: String?, image: String?) -> Episode {
            Episode(
                id: id, title: title, name: nil, season: 1, episode: number, overview: nil,
                thumbnail: image, released: nil, streams: nil, runtimeMinutes: nil)
        }
        let episodes = MetadataResolver.episodes(
            [episode("provider", number: 1, title: "TVDB", image: nil)],
            fillingFrom: [
                episode("other", number: 1, title: "TMDB", image: "image"),
                episode("unrelated", number: 2, title: nil, image: nil),
            ])
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.id, "provider")
        XCTAssertEqual(episodes.first?.title, "TVDB")
        XCTAssertEqual(episodes.first?.thumbnail, "image")
    }

    func testCancellingRefreshesRejectsOldWritesWithoutDeletingCachedData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ResponseCache(directory: directory)
        await disk.save("saved", key: "details")
        let token = await disk.token()
        await disk.cancelRefreshes()
        await disk.save("late", key: "details", token: token)
        let value = await disk.value(String.self, key: "details", ttl: 3600)
        XCTAssertEqual(value?.value, "saved")
    }

}
