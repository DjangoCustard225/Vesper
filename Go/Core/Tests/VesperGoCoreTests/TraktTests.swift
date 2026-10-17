import XCTest
@testable import VesperCore

final class GoTraktTests: XCTestCase {
    private func tokens() throws -> TraktTokens {
        try JSONDecoder().decode(
            TraktTokens.self,
            from: Data(
                """
                {"access_token":"access","refresh_token":"refresh","created_at":\(Int(Date().timeIntervalSince1970)),"expires_in":604800}
                """.utf8))
    }

    func testAccountAndEpisodeHistoryStillImportWithoutPlaybackTracking() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { request in
            switch request.url?.path {
            case "/users/settings":
                return (200, Data(#"{"user":{"username":"viewer","ids":{"uuid":"account"}}}"#.utf8))
            case "/sync/last_activities": return (200, Data(#"{"all":"revision"}"#.utf8))
            case "/sync/watched/movies": return (200, Data("[]".utf8))
            case "/sync/watched/shows":
                XCTAssertTrue(request.url?.query?.contains("extended=progress") == true)
                return (
                    200,
                    Data(
                        #"[{"last_watched_at":"2026-10-17T06:00:00.000Z","show":{"title":"Show","ids":{"trakt":1,"imdb":"tt123"}},"seasons":[{"number":1,"episodes":[{"number":2,"last_watched_at":"2026-10-17T06:00:00.000Z"}]}]}]"#
                            .utf8)
                )
            default: XCTFail("Unexpected request"); return (500, Data())
            }
        }
        let client = TraktClient(tokens: try tokens(), session: fixture.session())
        let account = try await client.account()
        XCTAssertEqual(account.id, "account")
        let result = try await client.watched(previousFingerprint: nil)
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entries.first?.videoID, "tt123:1:2")
        var history = WatchProgress()
        history.mergeTrakt(snapshot.entries, pending: [])
        XCTAssertEqual(history.records.first?.episodeKey, "1:2")
        XCTAssertTrue(history.records.first?.watched == true)
        history.detachTrakt()
        XCTAssertTrue(history.records.first?.watched == true)
    }

    func testManualMovieAndShowChangesUseHistoryEndpoints() async throws {
        for kind in ["movie", "show"] {
            let fixture = HTTPFixture()
            fixture.handler = { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
                switch request.url?.path {
                case "/search/imdb/tt123":
                    return (
                        200,
                        Data(
                            "[{\"\(kind)\":{\"title\":\"Title\",\"ids\":{\"trakt\":1,\"imdb\":\"tt123\"}}}]"
                                .utf8)
                    )
                case "/sync/history/movies/1": return (200, Data("[]".utf8))
                case "/shows/1/progress/watched": return (200, Data(#"{"aired":2,"completed":0}"#.utf8))
                case "/sync/history", "/sync/history/remove":
                    XCTAssertEqual(request.httpMethod, "POST")
                    let body = try XCTUnwrap(request.httpBody)
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    XCTAssertNotNil(object[kind + "s"])
                    XCTAssertNil(object["progress"])
                    return (200, Data(#"{"not_found":{}}"#.utf8))
                default: XCTFail("Unexpected request"); return (500, Data())
                }
            }
            let client = TraktClient(tokens: try tokens(), session: fixture.session())
            let media = MediaItem(id: "tt123", type: kind == "movie" ? "movie" : "series", name: "Title")
            try await client.apply(TraktHistoryChange(media: media, action: .watched))
            try await client.apply(TraktHistoryChange(media: media, action: .unwatched))
        }
    }

    func testPendingManualChangesRoundTripAndCoalesceWithoutScrobbleFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = TraktStateRepository(url: directory.appendingPathComponent("trakt.json"))
        let media = MediaItem(id: "tt123", type: "movie", name: "Title")
        var state = TraktSyncState()
        try state.enqueue(TraktHistoryChange(media: media, action: .watched))
        let latest = TraktHistoryChange(media: media, action: .unwatched)
        try state.enqueue(latest)
        try repository.save(state)
        let loaded = try repository.load()
        XCTAssertEqual(loaded.pending.count, 1)
        XCTAssertEqual(loaded.pending.first?.id, latest.id)
        XCTAssertEqual(loaded.pending.first?.action, .unwatched)
        let data = try JSONEncoder().encode(latest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["progress"])
        XCTAssertThrowsError(
            try JSONDecoder().decode(TraktHistoryChange.Action.self, from: Data(#""stopped""#.utf8)))
    }
}
