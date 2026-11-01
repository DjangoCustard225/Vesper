import XCTest
@testable import VesperCore

private actor InitialEpisodeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var arrived = false
    func wait() async { arrived = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class InitialEpisodeTests: XCTestCase {
    private let show = MediaItem(id: "tt123", type: "series", name: "Show")

    private func episode(_ number: Int, season: Int = 1, id: String? = nil, released: String? = nil)
        -> Episode
    {
        Episode(
            id: id ?? "tt123:\(season):\(number)", title: "Episode \(number)", name: nil,
            season: season, episode: number, overview: nil, thumbnail: nil, released: released,
            streams: nil, runtimeMinutes: nil)
    }

    private func media(_ episodes: [Episode]) -> MediaItem {
        var media = show; media.videos = episodes; return media
    }

    private func model(_ episodes: [Episode], resume: WatchRecord? = nil) async -> DetailLoadingController {
        let value = media(episodes)
        let model = DetailLoadingController(item: value, startPlayback: true, resumeRecord: resume)
        await model.load { ($0, nil) }
        return model
    }

    private func select(_ model: DetailLoadingController, history: WatchProgress = .init()) async {
        await model.selectInitialEpisode(history: history) { media, _, number in
            (media.videos ?? []).filter { $0.season == number }
        }
    }

    private func wait(_ gate: InitialEpisodeGate) async {
        for _ in 0..<500 {
            if await gate.arrived { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Request did not reach gate")
    }

    func testOpeningStartsAtFirstUnwatchedIncludingGapsAndPreservesEpisodeIdentity() async {
        let episodes = [episode(3), episode(1), episode(2, id: "provider-file-2")]
        var history = WatchProgress()
        history.setWatched(true, for: show, episode: episodes[1])
        history.setWatched(true, for: show, episode: episodes[0])
        let model = await model(episodes)
        await select(model, history: history)
        XCTAssertEqual(model.initialEpisode?.id, "provider-file-2")
        let choice = model.requestedPlayback()
        XCTAssertEqual(choice?.id, "provider-file-2")
        XCTAssertEqual(choice?.episode, episodes[2])
        XCTAssertNil(model.requestedPlayback())
    }

    func testFullyWatchedSeasonAdvancesToNextAndStopsFetchingAtFirstUnwatched() async throws {
        let episodes = [episode(1), episode(2), episode(1, season: 2), episode(1, season: 3)]
        var history = WatchProgress()
        for episode in episodes.prefix(2) { history.setWatched(true, for: show, episode: episode) }
        let model = await model(episodes)
        var requests: [Int] = []
        await model.selectInitialEpisode(history: history) { media, _, number in
            requests.append(number)
            return (media.videos ?? []).filter { $0.season == number }
        }
        XCTAssertEqual(requests, [1, 2])
        XCTAssertEqual(model.season, 2)
        XCTAssertEqual(model.initialEpisode?.episode, 1)
    }

    func testLocalProgressResumesCurrentEpisodeAheadOfEarlierUnwatchedGaps() async {
        let episodes = [episode(1), episode(2), episode(1, season: 2)]
        var history = WatchProgress()
        history.record(media: show, videoID: episodes[2].id, subtitle: "Resume", elapsed: 100, duration: 1000)
        let model = await model(episodes)
        await select(model, history: history)
        XCTAssertEqual(model.season, 2)
        XCTAssertEqual(model.requestedPlayback()?.id, episodes[2].id)
        XCTAssertEqual(history.resumePosition(for: show, videoID: episodes[2].id), 100)
    }

    func testExplicitContinueWatchingChoiceWinsOverNewerLocalProgress() async throws {
        let episodes = [episode(1), episode(2), episode(3)]
        var history = WatchProgress()
        history.record(media: show, videoID: episodes[1].id, subtitle: nil, elapsed: 20, duration: 200)
        let explicit = try XCTUnwrap(history.records.first)
        history.record(media: show, videoID: episodes[2].id, subtitle: nil, elapsed: 30, duration: 200)
        let model = await model(episodes, resume: explicit)
        await select(model, history: history)
        XCTAssertEqual(model.requestedPlayback()?.id, episodes[1].id)
    }

    func testTraktWatchedStateAndExplicitUnwatchedOverrideSelectSameEpisodeAsBadges() async {
        let episodes = [episode(1), episode(2), episode(3)]
        var history = WatchProgress()
        history.mergeTrakt(
            episodes.map {
                TraktWatchedEntry(media: show, videoID: $0.id, watchedAt: .distantPast)
            })
        history.setWatched(false, for: show, episode: episodes[1])
        let model = await model(episodes)
        await select(model, history: history)
        XCTAssertFalse(history.isWatched(show, episode: episodes[1]))
        XCTAssertEqual(model.initialEpisode?.id, episodes[1].id)
    }

    func testFullyWatchedShowDoesNotAutomaticallyReplayEpisodeOne() async {
        let episodes = [episode(1), episode(2)]
        var history = WatchProgress()
        history.setWatched(true, for: show)
        let model = await model(episodes)
        await select(model, history: history)
        XCTAssertNil(model.initialEpisode)
        XCTAssertNil(model.defaultPlayback())
        XCTAssertNil(model.requestedPlayback())
    }

    func testSpecialsDoNotPrecedeRegularEpisodesAndUnairedEpisodesAreNotPlayed() async throws {
        let episodes = [episode(1, season: 0), episode(1), episode(2, released: "2099-01-01"), episode(3)]
        let model = await model(episodes)
        await select(model)
        XCTAssertEqual(model.initialEpisode?.season, 1)
        var history = WatchProgress()
        history.setWatched(true, for: show, episode: episodes[1])
        let pending = await self.model(episodes)
        await select(pending, history: history)
        XCTAssertNil(pending.requestedPlayback())
        let specials = await self.model([episodes[0]])
        await select(specials)
        XCTAssertEqual(specials.initialEpisode?.season, 0)
    }

    func testFailedEarlierSeasonDoesNotGuessAndCanRetrySelection() async {
        let model = await model([episode(1), episode(2)])
        await model.selectInitialEpisode(history: .init()) { _, _, _ in
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertNotNil(model.initialEpisodeError)
        XCTAssertNil(model.requestedPlayback())
        XCTAssertNil(model.defaultPlayback())
        await select(model)
        XCTAssertNil(model.initialEpisodeError)
        XCTAssertEqual(model.requestedPlayback()?.id, "tt123:1:1")
    }

    func testLateResolutionCannotOverrideManualSeasonSelection() async {
        let model = await model([episode(1), episode(1, season: 2)])
        let gate = InitialEpisodeGate()
        let task = Task {
            await model.selectInitialEpisode(history: .init()) { _, _, _ in
                await gate.wait()
                return [self.episode(1)]
            }
        }
        await wait(gate)
        XCTAssertNil(model.requestedPlayback())
        model.season = 2
        await gate.open()
        await task.value
        XCTAssertEqual(model.season, 2)
        XCTAssertFalse(model.selectingInitialEpisode)
    }

    func testSupersededOrCancelledResolutionCannotPublishOldEpisode() async {
        let model = await model([episode(1)])
        let gate = InitialEpisodeGate()
        let task = Task {
            await model.selectInitialEpisode(history: .init()) { _, _, _ in
                await gate.wait()
                return [self.episode(1)]
            }
        }
        await wait(gate)
        task.cancel()
        await model.load { _ in (self.media([self.episode(2)]), nil) }
        await select(model)
        await gate.open()
        await task.value
        XCTAssertEqual(model.initialEpisode?.episode, 2)
        XCTAssertFalse(model.selectingInitialEpisode)
    }

    func testCustomEpisodeIDsWithoutNumberingStillSkipWatchedEntries() async {
        let first = Episode(
            id: "custom-one", title: "One", name: nil, season: nil, episode: nil,
            overview: nil, thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
        let second = Episode(
            id: "custom-two", title: "Two", name: nil, season: nil, episode: nil,
            overview: nil, thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
        var history = WatchProgress()
        history.setWatched(true, for: show, episode: first)
        let model = await model([first, second])
        await select(model, history: history)
        XCTAssertEqual(model.requestedPlayback()?.id, second.id)
    }
    func testSeasonChosenWhileWaitingForHistoryIsPreserved() async {
        let model = await model([episode(1), episode(1, season: 2)])
        model.selectSeason(2)
        await select(model)
        XCTAssertEqual(model.season, 2)
        XCTAssertEqual(model.initialEpisode?.season, 1)
    }

    func testMetadataBackedSelectionPublishesTheChosenSeasonAndItsEpisodes() async {
        let details = MetadataEnrichment(
            id: 42, mediaType: "tv", overview: nil, tagline: nil, posterURL: nil, textlessPosterURL: nil,
            backdropURL: nil, titleLogoURL: nil, releaseYear: nil, runtimeMinutes: nil,
            genres: [], cast: [], directors: [], directorPeople: [], crew: nil,
            creators: [], rating: nil, voteCount: nil, imdbID: "tt123", seasons: [1, 2])
        let model = DetailLoadingController(item: show, startPlayback: true)
        await model.load(metadata: { ($0, nil) }, enrich: { _ in details })
        var history = WatchProgress()
        history.setWatched(true, for: show, episode: episode(1))
        await model.selectInitialEpisode(history: history) { _, _, number in
            [self.episode(1, season: number)]
        }
        XCTAssertEqual(model.season, 2)
        XCTAssertEqual(model.episodes.first?.id, "tt123:2:1")
        XCTAssertEqual(model.requestedPlayback()?.episode?.season, 2)
    }

    func testUnnumberedDefaultAndMoviePlaybackKeepWorkingWithoutEpisodeMetadata() async throws {
        var unnumbered = show
        unnumbered.behaviorHints = try JSONDecoder().decode(
            MediaHints.self, from: Data(#"{"defaultVideoId":"custom-file"}"#.utf8))
        let model = DetailLoadingController(item: unnumbered, startPlayback: true)
        await model.load { ($0, nil) }
        await select(model)
        XCTAssertEqual(model.requestedPlayback()?.id, "custom-file")
        let movie = MediaItem(id: "tt456", type: "movie", name: "Movie")
        let film = DetailLoadingController(item: movie, startPlayback: true)
        await film.load { ($0, nil) }
        await select(film)
        XCTAssertEqual(film.requestedPlayback()?.id, movie.playbackID)
    }

}
