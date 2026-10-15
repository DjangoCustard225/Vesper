import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class PersonFilmographyTests: XCTestCase {
    private let fixture = HTTPFixture()
    private let key = String(repeating: "a", count: 32)
    private let configuration =
        #"{"images":{"secure_base_url":"https://image.tmdb.org/t/p/","profile_sizes":["w185"],"poster_sizes":["w500"],"backdrop_sizes":["w1280"]}}"#
    private let response =
        #"{"id":7,"cast":[{"id":1,"media_type":"movie","title":"Zulu","release_date":"2000-01-01","genre_ids":[18],"popularity":20,"vote_average":8,"vote_count":100},{"id":1,"media_type":"movie","title":"Zulu","release_date":"2000-01-01","genre_ids":[18,35],"popularity":20,"poster_path":"/poster.jpg","vote_average":8,"vote_count":100},{"id":1,"media_type":"tv","name":"Alpha","first_air_date":"2020-01-01","genre_ids":[10765],"popularity":100,"vote_average":8,"vote_count":1000},{"id":2,"media_type":"movie","title":"Beta","release_date":"2025-06-01","genre_ids":[18,35],"popularity":50,"vote_average":7.5,"vote_count":50},{"id":3,"media_type":"movie","title":"No Date","release_date":"","genre_ids":[]},{"id":4,"media_type":"movie","title":"Adult","adult":true},{"id":0,"media_type":"movie","title":"Invalid"},{"id":5,"media_type":"person","name":"Another Actor"}],"crew":[{"id":6,"media_type":"movie","title":"Produced Only"}]}"#

    private func install(_ body: String? = nil, calls: LockedRequestCounter? = nil) {
        let configuration = configuration, response = body ?? response, key = key
        fixture.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "api_key" }?.value, key)
            switch request.url!.path {
            case "/3/configuration": return (200, Data(configuration.utf8))
            case "/3/genre/movie/list":
                return (200, Data(#"{"genres":[{"id":18,"name":"Drama"},{"id":35,"name":"Comedy"}]}"#.utf8))
            case "/3/genre/tv/list":
                return (
                    200,
                    Data(
                        #"{"genres":[{"id":18,"name":"Drama"},{"id":10765,"name":"Sci-Fi & Fantasy"}]}"#.utf8)
                )
            case "/3/person/7/combined_credits":
                calls?.increment()
                XCTAssertEqual(query?.first { $0.name == "language" }?.value, "en-US")
                XCTAssertNil(query?.first { $0.name == "page" || $0.name == "sort_by" })
                return (200, Data(response.utf8))
            default:
                XCTFail("Unexpected filmography endpoint")
                return (404, Data())
            }
        }
    }

    private func client(cache: ResponseCache? = nil) -> TMDBClient {
        TMDBClient(session: fixture.session(), cache: cache)
    }

    private func filmography() async throws -> PersonFilmography {
        install()
        return try await client().filmography(personID: 7, credential: key)
    }

    func testCombinedCastCreditsPreserveMovieTVIdentityAndMergeDuplicateRoles() async throws {
        let result = try await filmography()
        XCTAssertEqual(result.credits.count, 4)
        XCTAssertEqual(
            Set(result.credits.map(\.media.id)),
            ["tmdb:movie:1", "tmdb:tv:1", "tmdb:movie:2", "tmdb:movie:3"])
        let duplicate = try XCTUnwrap(result.credits.first { $0.media.id == "tmdb:movie:1" })
        XCTAssertEqual(duplicate.genreIDs, [18, 35])
        XCTAssertEqual(duplicate.media.poster, "https://image.tmdb.org/t/p/w500/poster.jpg")
        XCTAssertEqual(result.credits.first { $0.media.id == "tmdb:tv:1" }?.media.type, "series")
        XCTAssertEqual(result.genres.map(\.name), ["Comedy", "Drama", "Sci-Fi & Fantasy"])
    }

    func testPopularityAndRatingSortHighestFirst() async throws {
        let result = try await filmography()
        XCTAssertEqual(result.items().map(\.name), ["Alpha", "Beta", "Zulu", "No Date"])
        XCTAssertEqual(result.items(sort: .rating).map(\.name), ["Alpha", "Zulu", "Beta", "No Date"])
    }

    func testDateSortsKeepUnknownDatesLastInBothDirections() async throws {
        let result = try await filmography()
        XCTAssertEqual(result.items(sort: .newest).map(\.name), ["Beta", "Alpha", "Zulu", "No Date"])
        XCTAssertEqual(result.items(sort: .oldest).map(\.name), ["Zulu", "Alpha", "Beta", "No Date"])
        XCTAssertEqual(result.items(sort: .title).map(\.name), ["Alpha", "Beta", "No Date", "Zulu"])
    }

    func testFiltersIntersectAndAvailableGenresAndYearsFollowContentType() async throws {
        let result = try await filmography()
        XCTAssertEqual(result.items(type: "series").map(\.name), ["Alpha"])
        XCTAssertEqual(result.items(type: "movie", genreID: 18, year: 2025).map(\.name), ["Beta"])
        XCTAssertTrue(result.items(genreID: 999).isEmpty)
        XCTAssertTrue(result.items(type: "series", genreID: 18).isEmpty)
        XCTAssertEqual(result.genres(type: "series").map(\.id), [10765])
        XCTAssertEqual(result.years(type: "movie"), [2025, 2000])
        XCTAssertEqual(result.years(type: "series"), [2020])
    }

    func testStableTieOrderingDoesNotDependOnCreditResponseOrder() throws {
        let a = PersonCredit(
            media: MediaItem(id: "tmdb:movie:2", type: "movie", name: "Same"), genreIDs: [], popularity: 1,
            releaseDate: nil, voteCount: 0)
        let b = PersonCredit(
            media: MediaItem(id: "tmdb:movie:1", type: "movie", name: "Same"), genreIDs: [], popularity: 1,
            releaseDate: nil, voteCount: 0)
        for sort in FilmographySort.allCases {
            XCTAssertEqual(
                PersonFilmography(credits: [a, b], genres: []).items(sort: sort),
                PersonFilmography(credits: [b, a], genres: []).items(sort: sort))
        }
    }

    func testMemoryAndDiskCacheAvoidRepeatedRequests() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory), calls = LockedRequestCounter()
        install(calls: calls)
        let api = client(cache: cache)
        let first = try await api.filmography(personID: 7, credential: key)
        _ = try await api.filmography(personID: 7, credential: key)
        XCTAssertEqual(calls.value, 1)
        fixture.handler = { _ in
            XCTFail("Expected persistent filmography cache")
            return (500, Data())
        }
        let persisted = try await client(cache: cache).filmography(personID: 7, credential: key)
        XCTAssertEqual(persisted.credits, first.credits)
        XCTAssertEqual(persisted.genres, first.genres)
        for file in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        {
            XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains(key))
        }
    }

    func testStaleFilmographyRevalidatesAndPublishesOpaqueCacheID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory)
        install()
        let original = try await client(cache: cache).filmography(personID: 7, credential: key)
        let cacheKey = MetadataCacheKey.personFilmography(7, credential: key)
        await cache.save(original, key: cacheKey, now: Date().addingTimeInterval(-6 * 3600 - 1))
        install(response.replacingOccurrences(of: "Zulu", with: "Updated"))
        let refreshed = expectation(description: "Filmography revalidated")
        let observer = NotificationCenter.default.addObserver(
            forName: .vesperMetadataUpdated, object: nil, queue: nil
        ) { note in
            guard (note.object as? MetadataUpdate)?.cacheID == MetadataCacheKey.id(cacheKey) else { return }
            refreshed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let api = client(cache: cache)
        let stale = try await api.filmography(personID: 7, credential: key)
        XCTAssertEqual(stale.credits, original.credits)
        await fulfillment(of: [refreshed], timeout: 2)
        let fresh = try await api.filmography(personID: 7, credential: key)
        XCTAssertTrue(fresh.credits.contains { $0.media.name == "Updated" })
    }

    func testCredentialReplacementDoesNotReuseFilmography() async throws {
        install()
        let api = client()
        _ = try await api.filmography(personID: 7, credential: key)
        fixture.handler = { _ in (401, Data("private body".utf8)) }
        do {
            _ = try await api.filmography(personID: 7, credential: String(repeating: "b", count: 32))
            XCTFail("A new credential must authenticate its own requests")
        } catch { XCTAssertEqual(error as? TMDBError, .unauthorized) }
    }

    func testEmptyMissingAndMismatchedPersonResponses() async throws {
        install(#"{"id":7,"cast":[],"crew":[]}"#)
        let empty = try await client().filmography(personID: 7, credential: key)
        XCTAssertTrue(empty.credits.isEmpty)
        for body in [#"{"id":8,"cast":[]}"#, #"{"id":7,"crew":[]}"#, "not JSON"] {
            install(body)
            do {
                _ = try await client().filmography(personID: 7, credential: key)
                XCTFail()
            } catch {
                XCTAssertEqual(error as? TMDBError, .invalidResponse)
            }
        }
        fixture.handler = { _ in (404, Data()) }
        do {
            _ = try await client().filmography(personID: 7, credential: key)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TMDBError, .invalidResponse)
        }
    }

    func testInvalidPersonIDAndCancellation() async throws {
        fixture.handler = { _ in
            XCTFail("Invalid IDs must not make requests")
            return (500, Data())
        }
        do {
            _ = try await client().filmography(personID: 0, credential: key)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? TMDBError, .invalidResponse)
        }
        fixture.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await client().filmography(personID: 7, credential: key)
            XCTFail()
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor func testLateControllerResultCannotReplaceNewPerson() async {
        let model = PersonFilmographyController(), started = expectation(description: "First actor loading")
        var continuation: CheckedContinuation<PersonFilmography, Never>?
        let old = Task {
            await model.load {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        model.clear()
        let latest = PersonFilmography(credits: [], genres: [TMDBGenre(id: 18, name: "Drama")])
        await model.load { latest }
        continuation?.resume(returning: PersonFilmography(credits: [], genres: []))
        await old.value
        XCTAssertEqual(model.value?.genres, latest.genres)
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.error)
    }

    @MainActor func testCancelledNonCooperativeLoadStopsSpinnerWithoutPublishing() async {
        let model = PersonFilmographyController(), started = expectation(description: "Actor loading")
        var continuation: CheckedContinuation<PersonFilmography, Never>?
        let task = Task {
            await model.load {
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        continuation?.resume(returning: PersonFilmography(credits: [], genres: []))
        await task.value
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.value)
        XCTAssertNil(model.error)
    }

    @MainActor func testFailedRefreshKeepsExistingFilmographyAndRetryClearsError() async {
        let model = PersonFilmographyController()
        let original = PersonFilmography(credits: [], genres: [TMDBGenre(id: 18, name: "Drama")])
        await model.load { original }
        await model.load { throw TMDBError.unavailable }
        XCTAssertEqual(model.value?.genres, original.genres)
        XCTAssertEqual(model.error, TMDBError.unavailable.localizedDescription)
        XCTAssertFalse(model.loading)
        await model.load { original }
        XCTAssertNil(model.error)
        XCTAssertFalse(model.loading)
    }
}
