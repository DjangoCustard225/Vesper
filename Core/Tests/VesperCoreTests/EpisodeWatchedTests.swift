import XCTest
@testable import VesperCore

final class EpisodeWatchedTests: XCTestCase {
    private let show = MediaItem(id: "tt123", type: "series", name: "Show")

    private func episode(_ number: Int, id: String? = nil, season: Int = 1) -> Episode {
        Episode(
            id: id ?? "tt123:\(season):\(number)", title: "Episode \(number)", name: nil,
            season: season, episode: number, overview: nil, thumbnail: nil, released: nil,
            streams: nil, runtimeMinutes: nil)
    }

    func testEpisodeChoicesRemainIndependentAndOverrideWholeShowMarks() throws {
        var history = WatchProgress()
        history.setWatched(true, for: show, episode: episode(1))
        history.setWatched(true, for: show, episode: episode(2))
        history.setWatched(false, for: show, episode: episode(1))
        XCTAssertFalse(history.isWatched(show, episode: episode(1)))
        XCTAssertTrue(history.isWatched(show, episode: episode(2)))
        XCTAssertFalse(history.isWatched(show))
        history.setWatched(true, for: show)
        history.setWatched(false, for: show, episode: episode(1))
        XCTAssertFalse(history.isWatched(show, episode: episode(1)))
        XCTAssertTrue(history.isWatched(show, episode: episode(2)))
        XCTAssertFalse(history.isWatched(show))
        XCTAssertTrue(history.isValid)
        XCTAssertTrue(history.continueWatching.isEmpty)
        XCTAssertEqual(history.resumePosition(for: show, videoID: episode(1).id), 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WatchProgressRepository(url: directory.appendingPathComponent("watched.json"))
        try repository.save(history)
        let restored = try repository.load().state
        XCTAssertFalse(restored.isWatched(show, episode: episode(1)))
        XCTAssertTrue(restored.isWatched(show, episode: episode(2)))
        for version in [1, 2] {
            let old = Data("{\"version\":\(version),\"progress\":{\"records\":[]}}".utf8)
            XCTAssertTrue(try WatchProgressRepository.decode(old).records.isEmpty)
        }
    }

    func testEpisodeIdentitySurvivesEnrichmentAndCustomPlaybackIDs() {
        var enriched = show
        enriched.tmdbID = 42
        let original = MediaItem(id: "tmdb:tv:42", type: "series", name: "Show")
        let custom = episode(2, id: "provider-file", season: 0)
        var history = WatchProgress()
        history.record(media: enriched, videoID: custom.id, subtitle: nil, elapsed: 50, duration: 100)
        history.setWatched(true, for: enriched, episode: custom)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.videoID, "tt123:0:2")
        XCTAssertTrue(history.isWatched(original, episode: custom))
        history.setWatched(false, for: original, episode: custom)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertFalse(history.isWatched(enriched, episode: custom))
        XCTAssertTrue(history.isValid)
    }

    func testOlderRemoteHistoryCannotUndoAnEpisodeReset() {
        let old = Date(timeIntervalSince1970: 100)
        let entries = [1, 2].map {
            TraktWatchedEntry(media: show, videoID: episode($0).id, watchedAt: old)
        }
        var history = WatchProgress()
        history.mergeTrakt(entries)
        history.setWatched(false, for: show, episode: episode(1), now: old.addingTimeInterval(10))
        history.mergeTrakt(entries)
        XCTAssertFalse(history.isWatched(show, episode: episode(1)))
        XCTAssertTrue(history.isWatched(show, episode: episode(2)))
        history.mergeTrakt([
            TraktWatchedEntry(media: show, videoID: episode(1).id, watchedAt: old.addingTimeInterval(20)),
            entries[1],
        ])
        XCTAssertTrue(history.isWatched(show, episode: episode(1)))
    }

    func testTargetedRefreshReplacesOnlyThatShowsImportedEpisodesAndKeepsLocalEdits() {
        let otherShow = MediaItem(id: "tt456", type: "series", name: "Other")
        var history = WatchProgress()
        history.mergeTrakt([
            TraktWatchedEntry(media: show, videoID: episode(1).id, watchedAt: Date()),
            TraktWatchedEntry(media: show, videoID: episode(3).id, watchedAt: Date()),
            TraktWatchedEntry(
                media: otherShow, videoID: "tt456:1:1", watchedAt: Date()),
        ])
        history.setWatched(false, for: show, episode: episode(1))

        history.replaceTraktHistory(
            for: show,
            with: [TraktWatchedEntry(media: show, videoID: episode(2).id, watchedAt: Date())],
            pending: [TraktHistoryChange(media: show, videoID: episode(1).id, action: .unwatched)])

        XCTAssertFalse(history.isWatched(show, episode: episode(1)))
        XCTAssertTrue(history.isWatched(show, episode: episode(2)))
        XCTAssertFalse(history.isWatched(show, episode: episode(3)))
        XCTAssertTrue(history.isWatched(otherShow, episode: episode(1)))
        XCTAssertTrue(history.isValid)
    }

    func testTraktTargetedProgressReturnsOnlyCompletedEpisodes() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { request in
            guard let path = request.url?.path else { XCTFail("Missing URL"); return (500, Data()) }
            if path == "/search/imdb/tt123" {
                return (
                    200,
                    Data(#"[{"show":{"title":"Show","ids":{"trakt":7,"imdb":"tt123"}}}]"#.utf8)
                )
            }
            if path == "/shows/7/progress/watched" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "specials" })?.value, "true")
                XCTAssertEqual(query?.first(where: { $0.name == "hidden" })?.value, "true")
                return (
                    200,
                    Data(
                        #"{"seasons":[{"number":1,"episodes":[{"number":1,"completed":true,"last_watched_at":"2026-10-01T12:00:00Z"},{"number":2,"completed":false,"last_watched_at":null},{"number":3,"completed":true,"last_watched_at":"2026-10-03T12:00:00Z"}]}]}"#
                            .utf8)
                )
            }
            XCTFail("Unexpected request: \(path)")
            return (500, Data())
        }
        let tokens = TraktTokens(
            accessToken: "access", refreshToken: "refresh", expiresIn: 3600,
            createdAt: Int(Date().timeIntervalSince1970))
        let client = TraktClient(tokens: tokens, session: fixture.session())

        let entries = try await client.watchedEpisodes(for: show)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.compactMap(\.videoID)), ["tt123:1:1", "tt123:1:3"])
    }

    func testOutboxCoalescesOnlyTheSelectedEpisodeAndKeepsWholeShowOrdering() throws {
        var state = TraktSyncState()
        for number in [1, 2] {
            try state.enqueue(TraktHistoryChange(media: show, videoID: episode(number).id, action: .watched))
        }
        try state.enqueue(TraktHistoryChange(media: show, videoID: episode(1).id, action: .unwatched))
        XCTAssertEqual(state.pending.count, 2)
        XCTAssertEqual(state.pending.first?.videoID, episode(2).id)
        XCTAssertEqual(state.pending.last?.action, .unwatched)
        try state.enqueue(TraktHistoryChange(media: show, action: .watched))
        XCTAssertEqual(state.pending.count, 1)
        try state.enqueue(TraktHistoryChange(media: show, videoID: episode(1).id, action: .unwatched))
        XCTAssertEqual(state.pending.count, 2)
        XCTAssertNil(state.pending.first?.videoID)
        XCTAssertEqual(state.pending.last?.videoID, episode(1).id)
    }

    func testTraktManualEpisodeMarksUseExactEpisodeIDWithoutScrobbling() async throws {
        let fixture = HTTPFixture()
        let writes = expectation(description: "Episode watched and unwatched requests")
        writes.expectedFulfillmentCount = 2
        fixture.handler = { request in
            switch request.url?.path {
            case "/search/imdb/tt123":
                return (200, Data(#"[{"show":{"title":"Show","ids":{"trakt":1,"imdb":"tt123"}}}]"#.utf8))
            case "/shows/1/seasons/1/episodes/2": return (200, Data(#"{"ids":{"trakt":22}}"#.utf8))
            case "/sync/history/episodes/22": return (200, Data("[]".utf8))
            case "/sync/history", "/sync/history/remove":
                let data = try XCTUnwrap(request.httpBody)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let episodes = try XCTUnwrap(body["episodes"] as? [[String: Any]])
                let ids = try XCTUnwrap(episodes.first?["ids"] as? [String: Any])
                XCTAssertEqual(ids["trakt"] as? Int, 22)
                XCTAssertNil(body["shows"])
                XCTAssertNil(body["progress"])
                writes.fulfill()
                return (200, Data(#"{"not_found":{}}"#.utf8))
            default: XCTFail("Unexpected request"); return (500, Data())
            }
        }
        let tokenData = Data(
            """
            {"access_token":"access","refresh_token":"refresh","created_at":\(Int(Date().timeIntervalSince1970)),"expires_in":604800}
            """.utf8)
        let client = TraktClient(
            tokens: try JSONDecoder().decode(TraktTokens.self, from: tokenData), session: fixture.session())
        for action: TraktHistoryChange.Action in [.watched, .unwatched] {
            try await client.apply(TraktHistoryChange(media: show, videoID: episode(2).id, action: action))
        }
        await fulfillment(of: [writes], timeout: 1)
    }
}
