import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class TMDBTests: XCTestCase {
    private let key = String(repeating: "a", count: 32)
    private let config = #"{"images":{"secure_base_url":"https://image.tmdb.org/t/p/","profile_sizes":["w45","w185","original"],"poster_sizes":["w500","original"],"backdrop_sizes":["w1280","original"]}}"#
    private let movie = #"{"id":42,"overview":"Enriched synopsis","tagline":"A new adventure","poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg","release_date":"2026-09-01","runtime":120,"genres":[{"name":"Drama"}],"vote_average":8.2,"vote_count":1200,"credits":{"cast":[{"id":7,"name":"First Actor","character":"The Pilot","profile_path":"/portrait.jpg"},{"id":8,"name":"Second Actor","character":"The Captain","profile_path":null},{"id":7,"name":"First Actor","character":"Duplicate","profile_path":"/portrait.jpg"}],"crew":[{"id":9,"name":"Director Name","job":"Director"}]}}"#
    private func client() -> TMDBClient {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [FixtureURLProtocol.self]
        return TMDBClient(session: URLSession(configuration: session))
    }
    private func item(_ id: String = "tt123", type: String = "movie") throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: Data("""
        {"id":"\(id)","type":"\(type)","name":"Original title","imdbRating":"7.9","releaseInfo":"2020-","videos":[{"id":"tt123:1:1","title":"Pilot","season":1,"episode":1,"streams":[{"url":"https://source.example/video.mp4"}]}],"behaviorHints":{"defaultVideoId":"tt123:1:1"}}
        """.utf8))
    }
    private func installMovieFixture() {
        let config = config, movie = movie
        FixtureURLProtocol.handler = { request in
            switch request.url!.path {
            case "/3/configuration": return (200, Data(config.utf8))
            case "/3/find/tt123": return (200, Data(#"{"movie_results":[{"id":42}],"tv_results":[{"id":99}]}"#.utf8))
            case "/3/movie/42": return (200, Data(movie.utf8))
            default: XCTFail("Unexpected TMDB endpoint"); return (404, Data())
            }
        }
    }
    override func tearDown() { FixtureURLProtocol.handler = nil; super.tearDown() }

    func testAPIKeyAndBearerAuthentication() throws {
        let api = try TMDBClient.request(path: ["movie", "42"], credential: " \(key)\n")
        XCTAssertNil(api.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(URLComponents(url: api.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "api_key" }?.value, key)
        let token = "eyJ.fakeReadAccessToken.signature"
        let bearer = try TMDBClient.request(path: ["configuration"], credential: "Bearer " + token)
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
        XCTAssertFalse(bearer.url!.absoluteString.contains(token))
        XCTAssertEqual(try TMDBClient.normalizedCredential(" Bearer " + token + "\n"), token)
        XCTAssertThrowsError(try TMDBClient.normalizedCredential(""))
        XCTAssertThrowsError(try TMDBClient.normalizedCredential("eyJ.test\r\nAuthorization: evil"))
    }
    func testMovieCastPortraitsAndSafeMerge() async throws {
        installMovieFixture()
        let original = try item()
        let result = try await client().enrichment(for: original, credential: key)
        let enriched = try XCTUnwrap(result)
        XCTAssertEqual(enriched.cast.count, 2)
        XCTAssertEqual(enriched.cast[0].portraitURL, "https://image.tmdb.org/t/p/w185/portrait.jpg")
        XCTAssertNil(enriched.cast[1].portraitURL)
        XCTAssertEqual(enriched.cast[0].character, "The Pilot")
        XCTAssertEqual(enriched.directors, ["Director Name"])
        let merged = enriched.applying(to: original)
        XCTAssertEqual(merged.id, original.id)
        XCTAssertEqual(merged.name, original.name)
        XCTAssertEqual(merged.type, original.type)
        XCTAssertEqual(merged.videos, original.videos)
        XCTAssertEqual(merged.behaviorHints, original.behaviorHints)
        XCTAssertEqual(merged.imdbRating, "7.9")
        XCTAssertEqual(merged.description, "Enriched synopsis")
        XCTAssertEqual(merged.runtime, "120 min")
        XCTAssertEqual(merged.background, "https://image.tmdb.org/t/p/w1280/backdrop.jpg")
        XCTAssertEqual(merged.releaseInfo, "2026")
    }
    func testSeriesSelectsTVMatchAndAggregateRoles() async throws {
        let config = config
        FixtureURLProtocol.handler = { request in
            switch request.url!.path {
            case "/3/configuration": return (200, Data(config.utf8))
            case "/3/find/tt123": return (200, Data(#"{"movie_results":[{"id":42}],"tv_results":[{"id":99}]}"#.utf8))
            case "/3/tv/99":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "append_to_response" }?.value, "aggregate_credits,external_ids,images")
                return (200, Data(#"{"id":99,"first_air_date":"2020-01-01","episode_run_time":[0,45],"created_by":[{"id":10,"name":"Creator Name"}],"aggregate_credits":{"cast":[{"id":11,"name":"Series Actor","profile_path":"/actor.jpg","roles":[{"character":"One"},{"character":"Two"},{"character":"One"}]}],"crew":[]}}"#.utf8))
            default: XCTFail("Unexpected TMDB endpoint"); return (404, Data())
            }
        }
        let original = try item(type: "series")
        let result = try await client().enrichment(for: original, credential: key)
        XCTAssertEqual(result?.cast.first?.character, "One, Two")
        XCTAssertEqual(result?.creators, ["Creator Name"])
        XCTAssertEqual(result?.runtimeMinutes, 45)
        XCTAssertEqual(result?.applying(to: original).releaseInfo, "2020-")
    }
    func testDirectTMDBIDSkipsFind() async throws {
        installMovieFixture()
        let result = try await client().enrichment(for: item("tmdb:movie:42"), credential: key)
        XCTAssertEqual(result?.id, 42)
    }
    func testUnsupportedIDsAndMismatchedTypeDoNotQueryTMDB() async throws {
        FixtureURLProtocol.handler = { _ in XCTFail("Custom IDs must not be guessed by title"); return (500, Data()) }
        let api = client()
        let custom = try await api.enrichment(for: item("custom:42"), credential: key)
        let wrongType = try await api.enrichment(for: item("tmdb:tv:42"), credential: key)
        let live = try await api.enrichment(for: item("tt123", type: "tv"), credential: key)
        XCTAssertNil(custom); XCTAssertNil(wrongType); XCTAssertNil(live)
    }
    func testUnmatchedIMDbIDDoesNotReplaceMetadata() async throws {
        FixtureURLProtocol.handler = { _ in (200, Data(#"{"movie_results":[],"tv_results":[]}"#.utf8)) }
        let result = try await client().enrichment(for: item(), credential: key)
        XCTAssertNil(result)
    }
    func testEmptyFieldsPreserveAddOnDetails() async throws {
        let config = config
        FixtureURLProtocol.handler = { request in
            if request.url!.path == "/3/configuration" { return (200, Data(config.utf8)) }
            return (200, Data(#"{"id":42,"overview":"","poster_path":null,"backdrop_path":null,"genres":[],"credits":{"cast":[],"crew":[]},"vote_average":0,"vote_count":0}"#.utf8))
        }
        var original = try item("tmdb:42")
        original.description = "Add-on synopsis"; original.poster = "https://addon.example/poster.jpg"
        let result = try await client().enrichment(for: original, credential: key)
        let merged = try XCTUnwrap(result).applying(to: original)
        XCTAssertEqual(merged.description, original.description)
        XCTAssertEqual(merged.poster, original.poster)
        XCTAssertNil(result?.rating)
    }
    func testCredentialValidationAndImageOrigin() async throws {
        let config = config
        FixtureURLProtocol.handler = { _ in (200, Data(config.utf8)) }
        try await client().validate(credential: key)
        FixtureURLProtocol.handler = { _ in (200, Data(config.replacingOccurrences(of: "https://image.tmdb.org", with: "https://untrusted.example").utf8)) }
        do { try await client().validate(credential: key); XCTFail() }
        catch { XCTAssertEqual(error as? TMDBError, .invalidResponse) }
    }
    func testHTTPFailuresDoNotExposeCredentialsOrBodies() async {
        for (status, expected) in [(401, TMDBError.unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .http(500))] {
            FixtureURLProtocol.handler = { _ in (status, Data("private response with secret-token".utf8)) }
            do { try await client().validate(credential: key); XCTFail() }
            catch {
                XCTAssertEqual(error as? TMDBError, expected)
                XCTAssertFalse(error.localizedDescription.contains(key))
                XCTAssertFalse(error.localizedDescription.contains("secret-token"))
            }
        }
    }
    func testMalformedJSONAndCancelledRequests() async {
        FixtureURLProtocol.handler = { _ in (200, Data("<html>unavailable</html>".utf8)) }
        do { try await client().validate(credential: key); XCTFail() }
        catch { XCTAssertEqual(error as? TMDBError, .invalidResponse) }
        FixtureURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do { try await client().validate(credential: key); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testMetadataCacheAndCredentialReplacement() async throws {
        installMovieFixture()
        let api = client(), original = try item()
        let first = try await api.enrichment(for: original, credential: key)
        // A repeat must use the successful cached enrichment without another HTTP request.
        FixtureURLProtocol.handler = { _ in XCTFail("Expected cached enrichment"); return (500, Data()) }
        let cached = try await api.enrichment(for: original, credential: key)
        XCTAssertEqual(first, cached)
        // Replacing a key must not reuse a previous key's cached result.
        FixtureURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await api.enrichment(for: original, credential: String(repeating: "b", count: 32)); XCTFail() }
        catch { XCTAssertEqual(error as? TMDBError, .unauthorized) }
    }

    func testConcurrentHeroAndDetailMetadataShareDownloads() async throws {
        let calls = LockedRequestCounter(), config = config, movie = movie
        FixtureURLProtocol.handler = { request in
            if request.url!.path == "/3/configuration" { return (200, Data(config.utf8)) }
            calls.increment(); Thread.sleep(forTimeInterval: 0.03)
            return (200, Data(movie.utf8))
        }
        let api = client(), original = try item("tmdb:movie:42")
        async let hero = api.enrichment(for: original, credential: key)
        async let details = api.enrichment(for: original, credential: key)
        let (a, b) = try await (hero, details)
        XCTAssertEqual(a, b)
        XCTAssertEqual(calls.value, 1)
    }

    func testCancellingOneMetadataConsumerKeepsOtherConsumerLoading() async throws {
        let started = expectation(description: "Details request started")
        let calls = LockedRequestCounter(), config = config, movie = movie
        FixtureURLProtocol.handler = { request in
            if request.url!.path == "/3/configuration" { return (200, Data(config.utf8)) }
            calls.increment(); started.fulfill(); Thread.sleep(forTimeInterval: 0.08)
            return (200, Data(movie.utf8))
        }
        let api = client(), original = try item("tmdb:movie:42"), credential = key
        let first = Task { try await api.enrichment(for: original, credential: credential) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await api.enrichment(for: original, credential: credential) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled consumer returned metadata") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await second.value
        XCTAssertEqual(result?.id, 42)
        XCTAssertEqual(calls.value, 1)
    }

    func testColdDetailsFetchDoesNotWaitForImageConfiguration() async throws {
        let detailsStarted = DispatchSemaphore(value: 0), config = config, movie = movie
        FixtureURLProtocol.handler = { request in
            if request.url!.path == "/3/configuration" {
                XCTAssertEqual(detailsStarted.wait(timeout: .now() + 2), .success)
                return (200, Data(config.utf8))
            }
            detailsStarted.signal()
            return (200, Data(movie.utf8))
        }
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ConcurrentTMDBFixtureURLProtocol.self]
        let api = TMDBClient(session: URLSession(configuration: session))
        let result = try await api.enrichment(for: item("tmdb:movie:42"), credential: key)
        XCTAssertEqual(result?.id, 42)
    }
    func testRedirectsDoNotForwardAuthentication() {
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://api.themoviedb.org/3/configuration")!)
        let response = HTTPURLResponse(url: task.originalRequest!.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let redirected = URLRequest(url: URL(string: "https://untrusted.example")!)
        var called = false
        TMDBRedirectGuard().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { request in
            called = true; XCTAssertNil(request)
        }
        XCTAssertTrue(called)
        session.invalidateAndCancel()
    }
}

extension TMDBTests {
    func testTitleLogoUsesEnglishArtworkAndRequestsNeutralFallbacks() async throws {
        let config = config
        FixtureURLProtocol.handler = { request in
            if request.url!.path == "/3/configuration" { return (200, Data(config.utf8)) }
            XCTAssertEqual(request.url!.path, "/3/movie/42")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "append_to_response" }?.value, "credits,external_ids,images")
            XCTAssertEqual(query.first { $0.name == "include_image_language" }?.value, "en,null")
            return (200, Data(#"{"id":42,"images":{"logos":[{"file_path":"/neutral.png","iso_639_1":null,"width":2000,"vote_average":9},{"file_path":"/english.png","iso_639_1":"en","width":500,"vote_average":6},{"file_path":"/foreign.png","iso_639_1":"fr","width":3000,"vote_average":10}]}}"#.utf8))
        }
        let result = try await client().enrichment(for: item("tmdb:movie:42"), credential: key)
        XCTAssertEqual(result?.titleLogoURL, "https://image.tmdb.org/t/p/w500/english.png")
    }
    func testLogoSkipsUnsafePathsAndUnsupportedVectorFiles() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: Data(config.utf8))
        let details = try decoder.decode(TMDBDetails.self, from: Data(#"{"id":42,"images":{"logos":[{"file_path":"/../unsafe.png","iso_639_1":"en","vote_average":10},{"file_path":"/vector.svg","iso_639_1":"en","vote_average":9},{"file_path":"/foreign.png","iso_639_1":"de","vote_average":8},{"file_path":"/safe.png","iso_639_1":null,"vote_average":6}]}}"#.utf8))
        XCTAssertEqual(details.enrichment(type: "movie", configuration: configuration).titleLogoURL, "https://image.tmdb.org/t/p/w500/safe.png")
    }
    func testMovieDirectorsIncludeDeduplicatedPortraitsAndNamesWithoutImages() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: Data(config.utf8))
        let details = try decoder.decode(TMDBDetails.self, from: Data(#"{"id":42,"credits":{"crew":[{"id":1,"name":"Director One","job":"Director","profile_path":"/director.jpg"},{"id":1,"name":"Director One","job":"Director","profile_path":"/director.jpg"},{"id":2,"name":"Director Two","job":"Director","profile_path":null},{"id":3,"name":"Writer","job":"Writer","profile_path":"/writer.jpg"}]}}"#.utf8))
        let result = details.enrichment(type: "movie", configuration: configuration)
        XCTAssertEqual(result.directorPeople.map(\.id), [1, 2])
        XCTAssertEqual(result.directors, ["Director One", "Director Two"])
        XCTAssertEqual(result.directorPeople[0].portraitURL, "https://image.tmdb.org/t/p/w185/director.jpg")
        XCTAssertNil(result.directorPeople[1].portraitURL)
        XCTAssertEqual(result.directorPeople[0].website.absoluteString, "https://www.themoviedb.org/person/1")
    }
    func testSeriesDirectorsAreRecognizedFromAggregateJobs() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: Data(config.utf8))
        let details = try decoder.decode(TMDBDetails.self, from: Data(#"{"id":42,"aggregate_credits":{"crew":[{"id":10,"name":"Series Director","profile_path":"/series-director.jpg","jobs":[{"job":"Writer","episode_count":2},{"job":"Director","episode_count":8}]},{"id":11,"name":"Producer","jobs":[{"job":"Producer","episode_count":10}]}]}}"#.utf8))
        let result = details.enrichment(type: "tv", configuration: configuration)
        XCTAssertEqual(result.directors, ["Series Director"])
        XCTAssertEqual(result.directorPeople.count, 1)
        XCTAssertEqual(result.directorPeople[0].portraitURL, "https://image.tmdb.org/t/p/w185/series-director.jpg")
    }
    func testAbsentLogoAndCrewKeepMetadataAvailable() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: Data(config.utf8))
        let details = try decoder.decode(TMDBDetails.self, from: Data(#"{"id":42,"overview":"Still available","images":{"logos":[]}}"#.utf8))
        let result = details.enrichment(type: "movie", configuration: configuration)
        XCTAssertNil(result.titleLogoURL)
        XCTAssertTrue(result.directorPeople.isEmpty)
        XCTAssertEqual(result.overview, "Still available")
    }
    func testMovieCrewMergesJobsAndKeepsAvailablePortraits() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: Data(config.utf8))
        let details = try decoder.decode(TMDBDetails.self, from: Data(#"{"id":42,"credits":{"crew":[{"id":2,"name":"Producer","job":"Producer"},{"id":1,"name":"Filmmaker","job":"Writer"},{"id":1,"name":"Filmmaker","job":"Director","profile_path":"/director.jpg"},{"id":1,"name":"Filmmaker","job":" Writer "},{"id":3,"name":"Composer","job":"Original Music Composer","profile_path":"/../unsafe.jpg"},{"id":0,"name":"Invalid","job":"Director"},{"id":4,"name":"  ","job":"Writer"}]}}"#.utf8))
        let crew = try XCTUnwrap(details.enrichment(type: "movie", configuration: configuration).crew)
        XCTAssertEqual(crew.map(\.id), [1, 2, 3])
        XCTAssertEqual(crew[0].jobs, ["Writer", "Director"])
        XCTAssertEqual(crew[0].portraitURL, "https://image.tmdb.org/t/p/w185/director.jpg")
        XCTAssertNil(crew[1].portraitURL)
        XCTAssertNil(crew[2].portraitURL)
        XCTAssertEqual(crew[0].website.absoluteString, "https://www.themoviedb.org/person/1")
    }

    func testSeriesCrewCombinesAggregateJobsAndCreators() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: Data(config.utf8))
        let details = try decoder.decode(TMDBDetails.self, from: Data(#"{"id":42,"created_by":[{"id":10,"name":"Showrunner","profile_path":"/creator.jpg"},{"id":12,"name":"Co-Creator"}],"aggregate_credits":{"crew":[{"id":10,"name":"Showrunner","jobs":[{"job":"Writer"},{"job":"Director"},{"job":"Writer"},{"job":" "}]},{"id":11,"name":"Producer","jobs":[{"job":"Executive Producer"}]}]}}"#.utf8))
        let crew = try XCTUnwrap(details.enrichment(type: "tv", configuration: configuration).crew)
        XCTAssertEqual(crew.map(\.id), [10, 11, 12])
        XCTAssertEqual(crew[0].jobs, ["Writer", "Director", "Creator"])
        XCTAssertEqual(crew[0].portraitURL, "https://image.tmdb.org/t/p/w185/creator.jpg")
        XCTAssertEqual(crew[2].jobs, ["Creator"])
    }

    func testCrewLimitPreservesDirectorsAndStableCreditOrder() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: Data(config.utf8))
        let people: [[String: Any]] = (1...70).map { ["id": $0, "name": "Person \($0)", "job": $0 == 70 ? "Director" : "Producer"] }
        let data = try JSONSerialization.data(withJSONObject: ["id": 42, "credits": ["crew": people]])
        let details = try decoder.decode(TMDBDetails.self, from: data)
        let crew = try XCTUnwrap(details.enrichment(type: "movie", configuration: configuration).crew)
        XCTAssertEqual(crew.count, 60)
        XCTAssertEqual(crew.first?.id, 70)
        XCTAssertEqual(Array(crew.dropFirst().map(\.id)), Array(1...59))
    }

    func testEnrichmentWithoutCrewRemainsDecodable() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let configuration = try decoder.decode(TMDBConfiguration.self, from: Data(config.utf8))
        let details = try decoder.decode(TMDBDetails.self, from: Data(movie.utf8))
        let enrichment = details.enrichment(type: "movie", configuration: configuration)
        XCTAssertEqual(try JSONDecoder().decode(TMDBEnrichment.self, from: JSONEncoder().encode(enrichment)), enrichment)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(enrichment)) as? [String: Any])
        legacy.removeValue(forKey: "crew")
        let decoded = try JSONDecoder().decode(TMDBEnrichment.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.crew)
        XCTAssertEqual(decoded.directors, ["Director Name"])
        XCTAssertEqual(decoded.directorPeople.count, 1)
    }
}
