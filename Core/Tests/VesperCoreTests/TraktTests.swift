import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VesperCore

final class TraktClientTests: XCTestCase {
    private func tokens(expired: Bool = false) throws -> TraktTokens {
        try JSONDecoder().decode(
            TraktTokens.self,
            from: Data(
                """
                {"access_token":"old-access","refresh_token":"old-refresh","created_at":\(expired ? 0 : Int(Date().timeIntervalSince1970)),"expires_in":604800}
                """.utf8))
    }

    private let account = Data(
        #"{"user":{"username":"viewer","name":"Viewer","ids":{"slug":"viewer","uuid":"account-one"}}}"#.utf8)
    private let device = Data(
        #"{"device_code":"private-device-code","user_code":"ABCD1234","verification_url":"https://auth.trakt.tv/activate","expires_in":600,"interval":1}"#
            .utf8)

    func testHTTPFixtureMaterializesStreamedRequestBody() throws {
        let expectedBody = Data(#"{"client_id":"public-client"}"#.utf8)
        var request = URLRequest(url: URL(string: "https://fixture.invalid/body")!)
        request.httpBodyStream = InputStream(data: expectedBody)

        let materialized = try HTTPFixture.materializingRequestBody(in: request)
        XCTAssertEqual(materialized.httpBody, expectedBody)
        XCTAssertNil(materialized.httpBodyStream)
    }

    func testDeviceFlowUsesAuthHostAndNoClientSecret() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { request in
            XCTAssertEqual(request.url?.host, "auth.trakt.tv")
            XCTAssertEqual(request.value(forHTTPHeaderField: "trakt-api-key"), "public-client")
            let body = try XCTUnwrap(request.httpBody).jsonObject()
            XCTAssertNil(body["client_secret"])
            XCTAssertEqual(body["client_id"] as? String, "public-client")
            return (200, self.device)
        }
        let client = TraktClient(clientID: "public-client", session: fixture.session())
        let code = try await client.beginAuthorization()
        XCTAssertEqual(code.userCode, "ABCD1234")
        XCTAssertEqual(code.verificationURL.host, "auth.trakt.tv")
    }

    func testPendingAuthorizationAndCancellationDoNotStoreTokens() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { request in
            request.url?.path == "/oauth/device/code" ? (200, self.device) : (400, Data())
        }
        let client = TraktClient(session: fixture.session())
        let code = try await client.beginAuthorization()
        let approved = try await client.pollAuthorization(code)
        XCTAssertFalse(approved)
        await client.cancelAuthorization()
        do {
            _ = try await client.pollAuthorization(code); XCTFail("Cancelled authorization must stop polling")
        } catch is CancellationError {}
    }

    func testConcurrentCallsRotateRefreshTokenOnceAndPersistBeforeUse() async throws {
        let fixture = HTTPFixture()
        let store = TraktTokenRecorder()
        fixture.handler = { request in
            if request.url?.path == "/oauth/token" {
                store.incrementRefresh()
                let body = try XCTUnwrap(request.httpBody).jsonObject()
                XCTAssertNil(body["client_secret"])
                XCTAssertEqual(body["refresh_token"] as? String, "old-refresh")
                return (
                    200,
                    Data(
                        """
                        {"access_token":"new-access","refresh_token":"new-refresh","created_at":\(Int(Date().timeIntervalSince1970)),"expires_in":604800}
                        """.utf8)
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            XCTAssertEqual(store.token?.refreshToken, "new-refresh")
            return (200, self.account)
        }
        let client = TraktClient(tokens: try tokens(expired: true), session: fixture.session()) {
            store.save($0)
        }
        async let first = client.account()
        async let second = client.account()
        _ = try await (first, second)
        XCTAssertEqual(store.refreshes, 1)
    }

    func testRefreshPersistenceFailureDoesNotSendAuthenticatedRequest() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { request in
            XCTAssertEqual(request.url?.path, "/oauth/token")
            return (
                200,
                Data(
                    """
                    {"access_token":"new","refresh_token":"rotated","created_at":\(Int(Date().timeIntervalSince1970)),"expires_in":604800}
                    """.utf8)
            )
        }
        let client = TraktClient(tokens: try tokens(expired: true), session: fixture.session()) { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }
        do { _ = try await client.account(); XCTFail("A rotating token must be durably stored") } catch {
            XCTAssertTrue(error is CocoaError)
        }
    }

    func testUntrustedDeviceVerificationURLIsRejected() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { _ in
            (
                200,
                Data(
                    #"{"device_code":"code","user_code":"code","verification_url":"https://example.com/activate","expires_in":600,"interval":5}"#
                        .utf8)
            )
        }
        let client = TraktClient(session: fixture.session())
        do {
            _ = try await client.beginAuthorization(); XCTFail("Only Trakt verification hosts are valid")
        } catch { XCTAssertEqual(error as? TraktError, .invalidResponse) }
    }

    func testEpisodeScrobbleUsesResolvedEpisodeIDAndFiniteClampedProgress() async throws {
        let fixture = HTTPFixture()
        let writes = LockedRequestCounter()
        fixture.handler = { request in
            switch request.url?.path {
            case "/search/imdb/tt123":
                XCTAssertEqual(
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query, "type=show")
                return (200, Data(#"[{"show":{"title":"Show","ids":{"trakt":9,"imdb":"tt123"}}}]"#.utf8))
            case "/shows/9/seasons/2/episodes/3":
                return (200, Data(#"{"ids":{"trakt":99}}"#.utf8))
            case "/scrobble/start":
                writes.increment()
                let body = try XCTUnwrap(request.httpBody).jsonObject()
                XCTAssertEqual(body["progress"] as? Double, 100)
                XCTAssertEqual(
                    ((body["episode"] as? [String: Any])?["ids"] as? [String: Any])?["trakt"] as? Int, 99)
                XCTAssertNil(body["movie"])
                return (201, Data(#"{"action":"start"}"#.utf8))
            default: XCTFail("Unexpected request"); return (500, Data())
            }
        }
        let client = TraktClient(tokens: try tokens(), session: fixture.session())
        try await client.scrobble(
            .start, media: MediaItem(id: "tt123", type: "series", name: "Show"), videoID: "tt123:2:3",
            progress: 120)
        XCTAssertEqual(writes.value, 1)
    }

    func testAmbiguousExactIDResultsAreNotGuessedByName() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { _ in
            (
                200,
                Data(
                    #"[{"movie":{"title":"Same","ids":{"trakt":1,"imdb":"tt123"}}},{"movie":{"title":"Same","ids":{"trakt":2,"imdb":"tt123"}}}]"#
                        .utf8)
            )
        }
        let client = TraktClient(tokens: try tokens(), session: fixture.session())
        do {
            try await client.scrobble(
                .start, media: MediaItem(id: "tt123", type: "movie", name: "Same"), videoID: "tt123",
                progress: 10)
            XCTFail("Ambiguous IDs must not scrobble the wrong title")
        } catch { XCTAssertEqual(error as? TraktError, .unidentifiedTitle) }
    }

    func testAlreadyWatchedManualChangeDoesNotAddDuplicatePlay() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/search/imdb/tt123" {
                return (200, Data(#"[{"movie":{"title":"Movie","ids":{"trakt":7,"imdb":"tt123"}}}]"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/sync/history/movies/7")
            return (200, Data(#"[{"id":12345678901}]"#.utf8))
        }
        let client = TraktClient(tokens: try tokens(), session: fixture.session())
        try await client.apply(
            TraktHistoryChange(media: MediaItem(id: "tt123", type: "movie", name: "Movie"), action: .watched))
    }
}

final class TraktHistoryTests: XCTestCase {
    private let movie = MediaItem(id: "tt123", type: "movie", name: "Movie")
    private let show = MediaItem(id: "tt456", type: "series", name: "Show")

    func testImportedEpisodeIsWatchedWithoutInventingPlaybackProgress() throws {
        var history = WatchProgress()
        history.mergeTrakt([TraktWatchedEntry(media: show, videoID: "tt456:2:3", watchedAt: Date())])
        XCTAssertEqual(history.records.count, 1)
        XCTAssertTrue(history.records[0].watched)
        XCTAssertEqual(history.records[0].duration, 0)
        XCTAssertFalse(history.isWatched(show))
        XCTAssertTrue(history.continueWatching.isEmpty)
        XCTAssertTrue(history.isValid)
    }

    func testRemoteRemovalOnlyRemovesTraktManagedRecords() {
        var history = WatchProgress()
        history.setWatched(true, for: movie)
        history.mergeTrakt([TraktWatchedEntry(media: show, videoID: "tt456:1:1", watchedAt: Date())])
        history.mergeTrakt([])
        XCTAssertTrue(history.isWatched(movie))
        XCTAssertEqual(history.records.count, 1)
    }

    func testOlderRemoteCompletionDoesNotEraseNewerLocalRewatchOrArtwork() {
        var history = WatchProgress()
        let now = Date()
        var local = movie
        local.poster = "https://example.com/poster.jpg"
        history.record(media: local, videoID: movie.id, subtitle: nil, elapsed: 30, duration: 100, now: now)
        history.mergeTrakt([TraktWatchedEntry(media: movie, watchedAt: now.addingTimeInterval(-60))])
        XCTAssertFalse(history.isWatched(movie))
        XCTAssertEqual(history.resumePosition(for: movie, videoID: movie.id), 30)
        XCTAssertEqual(history.records.first?.media.poster, local.poster)
    }

    func testPendingUnwatchedChoiceWinsOverStaleRemoteHistory() {
        var history = WatchProgress()
        history.mergeTrakt([TraktWatchedEntry(media: movie, watchedAt: Date())])
        history.setWatched(false, for: movie)
        history.mergeTrakt(
            [TraktWatchedEntry(media: movie, watchedAt: Date())],
            pending: [TraktHistoryChange(media: movie, action: .unwatched)])
        XCTAssertFalse(history.isWatched(movie))
    }

    func testDisconnectPreservesImportedHistory() {
        var history = WatchProgress()
        history.mergeTrakt([TraktWatchedEntry(media: movie, watchedAt: Date())])
        history.detachTrakt()
        history.mergeTrakt([])
        XCTAssertTrue(history.isWatched(movie))
    }

    func testOutboxCoalescesManualChangesAndPreservesStoppedSessions() throws {
        var state = TraktSyncState()
        let stopped = TraktHistoryChange(media: movie, videoID: movie.id, action: .stopped, progress: 99)
        try state.enqueue(stopped)
        try state.enqueue(stopped)
        try state.enqueue(TraktHistoryChange(media: movie, action: .watched))
        try state.enqueue(TraktHistoryChange(media: movie, action: .unwatched))
        XCTAssertEqual(state.pending.count, 2)
        XCTAssertEqual(state.pending.last?.action, .unwatched)
    }

    func testOutboxSurvivesRestartWithoutTokensInFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = TraktStateRepository(url: root.appendingPathComponent("trakt.json"))
        var state = TraktSyncState()
        try state.enqueue(TraktHistoryChange(media: movie, action: .watched))
        try repository.save(state)
        XCTAssertEqual(try repository.load().pending.first?.id, state.pending.first?.id)
        XCTAssertFalse(try String(contentsOf: repository.url, encoding: .utf8).contains("access_token"))
    }

    func testOriginalProgressMigratesAndImportedEpisodesRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WatchProgressRepository(url: directory.appendingPathComponent("watch.json"))
        var history = try WatchProgressRepository.decode(
            Data(#"{"version":1,"progress":{"records":[]}}"#.utf8))
        history.mergeTrakt([TraktWatchedEntry(media: show, videoID: "tt456:1:2", watchedAt: Date())])
        try repository.save(history)
        XCTAssertEqual(try repository.load().state.records.first?.episodeKey, "1:2")
        let object = try Data(contentsOf: repository.url).jsonObject()
        XCTAssertEqual(object["version"] as? Int, 2)
    }

    func testPlaybackReporterIgnoresBufferingAndDeduplicatesStop() throws {
        var reporter = TraktPlaybackReporter()
        func sample(_ playing: Bool, buffering: Bool = false, ended: Bool = false, time: Double = 10)
            -> TraktPlaybackSample
        {
            TraktPlaybackSample(
                elapsed: time, duration: 100, playing: playing, buffering: buffering, ended: ended)
        }
        XCTAssertNil(reporter.update(sample(true, buffering: true)))
        let start = try XCTUnwrap(reporter.update(sample(true)))
        XCTAssertEqual(start.action, .start)
        XCTAssertNil(reporter.update(sample(true, time: 20)))
        XCTAssertNil(reporter.update(sample(false, buffering: true)))
        XCTAssertEqual(reporter.update(sample(false))?.action, .pause)
        XCTAssertEqual(reporter.update(sample(true))?.action, .start)
        XCTAssertEqual(reporter.update(sample(false, ended: true, time: 100))?.action, .stop)
        XCTAssertNil(reporter.finish())
        let replay = try XCTUnwrap(reporter.update(sample(true)))
        XCTAssertNotEqual(replay.sessionID, start.sessionID)
    }
}

private extension Data {
    func jsonObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
    }
}

private final class TraktTokenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TraktTokens?
    private var count = 0
    var token: TraktTokens? { lock.lock(); defer { lock.unlock() }; return value }
    var refreshes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func save(_ token: TraktTokens?) { lock.lock(); defer { lock.unlock() }; value = token }
    func incrementRefresh() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
