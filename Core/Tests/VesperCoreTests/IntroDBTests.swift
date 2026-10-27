import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class IntroDBTests: XCTestCase {
    private let fixture = HTTPFixture()
    private let episode = IntroEpisode(imdbID: "tt123", season: 1, episode: 2)!
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func body(intro: String = "{\"start_ms\":1500,\"end_ms\":61500}", imdb: String = "tt123") -> Data
    {
        Data(
            "{\"imdb_id\":\"\(imdb)\",\"season\":1,\"episode\":2,\"is_movie\":false,\"intro\":\(intro)}".utf8)
    }

    func testAnonymousEpisodeLookupAndMillisecondConversion() async throws {
        fixture.handler = { request in
            XCTAssertEqual(request.url?.host, "api.introdb.app")
            XCTAssertEqual(request.url?.path, "/segments")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.map(\.name), ["imdb_id", "season", "episode"])
            XCTAssertEqual(query?.map(\.value), ["tt123", "1", "2"])
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
            XCTAssertLessThanOrEqual(request.timeoutInterval, 4)
            return (200, self.body())
        }
        let client = IntroDBClient(session: fixture.session())
        let intro = try await client.segment(for: episode)
        XCTAssertEqual(intro?.startSeconds, 1.5)
        XCTAssertEqual(intro?.endSeconds, 61.5)
    }

    func testSharedLookupsAndPositiveCacheAvoidDuplicateRequestsUntilExpiry() async throws {
        let count = LockedRequestCounter()
        fixture.handler = { _ in
            count.increment()
            Thread.sleep(forTimeInterval: 0.03)
            return (200, self.body())
        }
        let client = IntroDBClient(session: fixture.session())
        async let first = client.segment(for: episode, now: now)
        async let second = client.segment(for: episode, now: now)
        let pair = try await (first, second)
        XCTAssertEqual(pair.0, pair.1)
        _ = try await client.segment(for: episode, now: now.addingTimeInterval(86_399))
        XCTAssertEqual(count.value, 1)
        _ = try await client.segment(for: episode, now: now.addingTimeInterval(86_401))
        XCTAssertEqual(count.value, 2)
    }

    func testMissingAndConfirmedAbsentIntrosUseOneHourNegativeCache() async throws {
        for status in [200, 404] {
            let count = LockedRequestCounter()
            fixture.handler = { _ in
                count.increment()
                return (status, status == 404 ? Data() : self.body(intro: "null"))
            }
            let client = IntroDBClient(session: fixture.session())
            let first = try await client.segment(for: episode, now: now)
            XCTAssertNil(first)
            _ = try await client.segment(for: episode, now: now.addingTimeInterval(3599))
            XCTAssertEqual(count.value, 1)
            _ = try await client.segment(for: episode, now: now.addingTimeInterval(3601))
            XCTAssertEqual(count.value, 2)
        }
        fixture.handler = { _ in
            (
                200,
                Data(
                    "{\"imdb_id\":\"tt123\",\"season\":1,\"episode\":2,\"no_intro\":true,\"intro\":{\"start_ms\":0,\"end_ms\":10000}}"
                        .utf8)
            )
        }
        let absent = try await IntroDBClient(session: fixture.session()).segment(for: episode)
        XCTAssertNil(absent)
    }

    func testInvalidResponsesAndHTTPFailuresAreNotRetriedOrCached() async throws {
        for (status, body) in [
            (500, self.body()), (429, self.body()), (200, self.body(imdb: "tt999")),
            (200, self.body(intro: "{\"start_ms\":5000,\"end_ms\":1000}")),
            (200, Data("invalid".utf8)),
            (
                200,
                Data(
                    String(decoding: self.body(), as: UTF8.self).replacingOccurrences(
                        of: "\"episode\":2", with: "\"episode\":3"
                    ).utf8)
            ),
        ] {
            let count = LockedRequestCounter()
            fixture.handler = { _ in
                count.increment(); return (status, body)
            }
            let client = IntroDBClient(session: fixture.session())
            for _ in 0..<2 {
                do { _ = try await client.segment(for: episode); XCTFail("Invalid response accepted") } catch
                {}
            }
            XCTAssertEqual(count.value, 2)
        }
    }

    func testPersistentCacheSurvivesRestartAndClearRemovesBothLayers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ResponseCache(directory: directory)
        let count = LockedRequestCounter()
        fixture.handler = { _ in
            count.increment(); return (200, self.body())
        }
        let first = IntroDBClient(session: fixture.session(), cache: disk)
        _ = try await first.segment(for: episode, now: now)
        let second = IntroDBClient(session: fixture.session(), cache: disk)
        _ = try await second.segment(for: episode, now: now.addingTimeInterval(60))
        XCTAssertEqual(count.value, 1)
        try await second.clearCache()
        _ = try await second.segment(for: episode, now: now.addingTimeInterval(61))
        XCTAssertEqual(count.value, 2)
    }

    func testTimeoutDoesNotRetryAndBorrowedSessionRemainsUsable() async throws {
        let session = fixture.session(), count = LockedRequestCounter()
        fixture.handler = { _ in
            count.increment(); throw URLError(.timedOut)
        }
        var client: IntroDBClient? = IntroDBClient(session: session)
        do { _ = try await client!.segment(for: episode); XCTFail("Timeout accepted") } catch {}
        XCTAssertEqual(count.value, 1)
        client = nil
        fixture.handler = { _ in (200, Data([1, 2, 3])) }
        let (data, _) = try await session.data(
            for: fixture.request(URL(string: "https://example.invalid/session")!))
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testPersistentAbsenceExpiresAfterOneHourRatherThanOneDay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = ResponseCache(directory: directory)
        let count = LockedRequestCounter()
        fixture.handler = { _ in
            count.increment(); return (404, Data())
        }
        let first = IntroDBClient(session: fixture.session(), cache: disk)
        _ = try await first.segment(for: episode, now: now)
        let second = IntroDBClient(session: fixture.session(), cache: disk)
        _ = try await second.segment(for: episode, now: now.addingTimeInterval(60))
        XCTAssertEqual(count.value, 1)
        fixture.handler = { _ in
            count.increment(); return (200, self.body())
        }
        let newIntro = try await second.segment(for: episode, now: now.addingTimeInterval(3601))
        XCTAssertNotNil(newIntro)
        XCTAssertEqual(count.value, 2)
    }

    func testCancellationAndClearRejectInFlightResponsesAndAllowFreshWork() async throws {
        let entered = expectation(description: "Lookup started")
        fixture.respond = { _ in
            entered.fulfill()
            var response = FixtureResponse(body: self.body())
            response.chunkInterval = 0.1
            return response
        }
        let client = IntroDBClient(session: fixture.session())
        let task = Task { try await client.segment(for: episode) }
        await fulfillment(of: [entered], timeout: 2)
        try await client.clearCache()
        do { _ = try await task.value; XCTFail("Stale lookup published after clear") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        fixture.handler = { _ in (200, self.body()) }
        let fresh = try await client.segment(for: episode)
        XCTAssertNotNil(fresh)
        let cancelled = Task { () throws -> IntroSegment? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.segment(for: self.episode)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled caller received a cached result") } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
