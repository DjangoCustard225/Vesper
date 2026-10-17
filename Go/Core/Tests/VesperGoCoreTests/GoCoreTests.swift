import XCTest
@testable import VesperCore

final class GoCoreTests: XCTestCase {
    func testOnlyExternalPlayersCanBeDecodedOrSelected() throws {
        XCTAssertEqual(VideoPlayer.allCases, [.vlc, .infuse, .outplayer])
        XCTAssertEqual(VideoPlayer.allCases, VideoPlayer.externalPlayers)
        for value in ["builtIn", "aether", "unknown", "vidhub", "other"] {
            XCTAssertNil(VideoPlayer(rawValue: value))
            XCTAssertThrowsError(try JSONDecoder().decode(VideoPlayer.self, from: Data("\"\(value)\"".utf8)))
            XCTAssertEqual(VideoPlayer.preferred(storedValue: value), .infuse)
        }
        XCTAssertEqual(VideoPlayer.preferred(storedValue: nil), .infuse)
        for player in VideoPlayer.allCases {
            XCTAssertEqual(VideoPlayer.preferred(storedValue: player.rawValue), player)
        }
    }

    func testExternalLaunchPreservesSignedUnicodeURL() throws {
        let stream = URL(string: "https://example.com/雪%20movie.mkv?token=a%2Fb+q&sign=x%3Dy#fragment")!
        for player in VideoPlayer.allCases where player.detectionURL != nil {
            let launch = try player.launchURL(for: stream)
            let components = try XCTUnwrap(URLComponents(url: launch, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, player.detectionURL?.scheme)
            XCTAssertEqual(components.path, player == .vlc ? "/stream" : "/play")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "url", value: stream.absoluteString)])
        }
    }

    func testExternalPlayersRejectUnsafeStreamSchemes() {
        for player in VideoPlayer.allCases {
            for value in ["file:///etc/passwd", "javascript:alert(1)", "ftp://example.com/file"] {
                XCTAssertThrowsError(try player.launchURL(for: URL(string: value)!))
            }
        }
    }

    func testGoDiscoveryAndFallbackNeverIntroduceInternalPlayers() {
        let outplayer = VideoPlayer.availablePlayers(VideoPlayer.allCases) { $0.scheme == "outplayer" }
        XCTAssertEqual(outplayer, [.outplayer])
        XCTAssertEqual(
            VideoPlayer.preferred(storedValue: "outplayer").availablePreference(in: outplayer), .outplayer)
        let empty = VideoPlayer.availablePlayers(VideoPlayer.allCases) { _ in false }
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(VideoPlayer.outplayer.availablePreference(in: empty), .outplayer)
    }

    func testManualSelectionKeepsAllExternalPlayersWhenContainerCannotQuerySchemes() throws {
        let available = VideoPlayer.availablePlayers(
            VideoPlayer.allCases, showAllExternalPlayers: true
        ) { _ in
            XCTFail("Manual selection must not depend on scheme queries")
            return false
        }
        XCTAssertEqual(available, [.vlc, .infuse, .outplayer])
        for player in available {
            XCTAssertEqual(player.availablePreference(in: available), player)
            XCTAssertNoThrow(try player.launchURL(for: URL(string: "https://example.com/movie.mkv")!))
        }
    }

    func testManualWatchedStateFollowsEnrichedTitleIdentity() {
        let original = MediaItem(id: "tmdb:movie:42", type: "movie", name: "Movie")
        var enriched = MediaItem(id: "tt123", type: "movie", name: "Movie")
        enriched.tmdbID = 42
        var state = WatchProgress()
        state.setWatched(true, for: original)
        XCTAssertTrue(state.isWatched(enriched))
        state.setWatched(false, for: enriched)
        XCTAssertTrue(state.records.isEmpty)
    }

    func testManualMarksPersistWithoutEmbeddedStreamMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WatchProgressRepository(url: directory.appendingPathComponent("watched.json"))
        let writer = WatchProgressWriter(repository: repository)
        var show = MediaItem(id: "tt123", type: "series", name: "Show")
        show.videos = [
            Episode(
                id: "private-stream", title: nil, name: nil, season: 1, episode: 1,
                overview: nil, thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
        ]
        var state = WatchProgress()
        state.setWatched(true, for: show)
        try await writer.save(state)
        let loaded = try repository.load()
        XCTAssertTrue(loaded.state.isWatched(show))
        XCTAssertFalse(loaded.recovered)
        XCTAssertNil(loaded.state.records.first?.media.videos)
        XCTAssertFalse(try String(contentsOf: repository.url, encoding: .utf8).contains("private-stream"))
        state.setWatched(false, for: show)
        try await writer.save(state)
        XCTAssertFalse(try repository.load().state.isWatched(show))
    }

    func testCorruptWatchedFileRecoversBackupAndPreservesDamage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WatchProgressRepository(url: directory.appendingPathComponent("watched.json"))
        let movie = MediaItem(id: "tt123", type: "movie", name: "Movie")
        var state = WatchProgress()
        state.setWatched(true, for: movie)
        try repository.save(state)
        try repository.save(state)
        let damaged = Data("corrupt".utf8)
        try damaged.write(to: repository.url)
        let loaded = try repository.load()
        XCTAssertTrue(loaded.recovered)
        XCTAssertTrue(loaded.state.isWatched(movie))
        try repository.save(loaded.state)
        let preserved = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.contains("corrupt-") })
        XCTAssertEqual(try Data(contentsOf: preserved), damaged)
    }

    @MainActor func testSeriesHeroPlaybackUsesFirstRegularSeasonEpisode() async throws {
        var show = MediaItem(id: "tt123", type: "series", name: "Show")
        show.videos = [0, 1].map { (season: Int) in
            Episode(
                id: "tt123:\(season):1", title: "Episode", name: nil, season: season, episode: 1,
                overview: nil, thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
        }
        let model = DetailLoadingController(item: show, startPlayback: true)
        await model.load(metadata: { ($0, nil) })
        XCTAssertEqual(model.season, 1)
        XCTAssertEqual(model.requestedPlayback()?.id, "tt123:1:1")
        XCTAssertNil(model.requestedPlayback(), "Automatic stream selection must happen only once")
    }

    @MainActor func testMovieHeroPlaybackPreservesIdentity() async {
        let movie = MediaItem(id: "tt123", type: "movie", name: "Movie")
        let model = DetailLoadingController(item: movie, startPlayback: true)
        await model.load(metadata: { ($0, nil) })
        XCTAssertEqual(model.requestedPlayback()?.id, movie.playbackID)
        XCTAssertNil(model.requestedPlayback())
    }
}
