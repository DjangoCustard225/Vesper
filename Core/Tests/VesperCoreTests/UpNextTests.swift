import XCTest
@testable import VesperCore

@MainActor final class UpNextTests: XCTestCase {
    private let show = MediaItem(id: "tt123", type: "series", name: "Show")
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func episode(_ number: Int, season: Int = 1, id: String? = nil, released: String? = nil)
        -> Episode
    {
        Episode(
            id: id ?? "tt123:\(season):\(number)", title: "Episode \(number)", name: nil,
            season: season, episode: number, overview: nil, thumbnail: nil, released: released,
            streams: nil, runtimeMinutes: nil)
    }

    func testSkipsWatchedEpisodesUsingEnrichedIdentityAndKeepsCustomPlaybackID() async throws {
        var enriched = show
        enriched.tmdbID = 42
        let catalogItem = MediaItem(id: "tmdb:tv:42", type: "series", name: "Show")
        var history = WatchProgress()
        history.setWatched(true, for: enriched, episode: episode(2))
        let next = try await UpNext.resolve(
            after: episode(1), seasons: [1], now: now,
            isWatched: { history.isWatched(catalogItem, episode: $0) },
            fetchSeason: { _ in [self.episode(3, id: "provider-file-3"), self.episode(2), self.episode(1)] })
        XCTAssertEqual(next?.id, "provider-file-3")
    }

    func testMovesAcrossSeasonsInOrderAndDoesNotFetchFurtherThanNeeded() async throws {
        var requested: [Int] = []
        let next = try await UpNext.resolve(
            after: episode(10), seasons: [3, 0, 1, 2, 2], now: now, isWatched: { _ in false }
        ) { season in
            requested.append(season)
            return season == 1 ? [self.episode(10)] : [self.episode(1, season: season)]
        }
        XCTAssertEqual(requested, [1, 2])
        XCTAssertEqual(next?.season, 2)
        XCTAssertEqual(next?.episode, 1)
    }

    func testSpecialsStaySeparateFromRegularSeasonChronology() async throws {
        var requested: [Int] = []
        let next = try await UpNext.resolve(
            after: episode(1, season: 0), seasons: [0, 1], now: now, isWatched: { _ in false }
        ) { season in
            requested.append(season)
            return [self.episode(1, season: season)]
        }
        XCTAssertNil(next)
        XCTAssertEqual(requested, [0])
    }

    func testUnairedOrMalformedReleaseDoesNotSkipForwardToUnknownDates() async throws {
        for date in ["2099-01-01", "2099-01-01T20:00:00.000Z", "unavailable"] {
            let next = try await UpNext.resolve(
                after: episode(1), seasons: [1, 2], now: now, isWatched: { _ in false },
                fetchSeason: { _ in [self.episode(2, released: date), self.episode(3)] })
            XCTAssertNil(next)
        }
        let aired = try await UpNext.resolve(
            after: episode(1), seasons: [1], now: now, isWatched: { _ in false },
            fetchSeason: { _ in [self.episode(2, released: "2020-01-01")] })
        XCTAssertEqual(aired?.episode, 2)
    }

    func testWholeShowWatchedAndEpisodeOverrideUseTheSameStateAsBadges() async throws {
        var history = WatchProgress()
        history.setWatched(true, for: show)
        history.setWatched(false, for: show, episode: episode(3))
        let next = try await UpNext.resolve(
            after: episode(1), seasons: [1], now: now,
            isWatched: { history.isWatched(self.show, episode: $0) },
            fetchSeason: { _ in [self.episode(1), self.episode(2), self.episode(3)] })
        XCTAssertFalse(history.isWatched(show))
        XCTAssertEqual(next?.episode, 3)
    }

    func testMissingOrDuplicatePlaybackIDsAndIncorrectSeasonsAreIgnored() async throws {
        let current = episode(1)
        let next = try await UpNext.resolve(
            after: current, seasons: [1], now: now, isWatched: { _ in false },
            fetchSeason: { _ in
                [
                    self.episode(2, id: ""), self.episode(3, id: current.id), self.episode(1, season: 2),
                    self.episode(4),
                ]
            })
        XCTAssertEqual(next?.episode, 4)
    }

    func testCurrentEpisodeResolvesKnownCustomIDsAndCanonicalResumeIDsOnly() {
        let custom = episode(2, id: "custom-file")
        XCTAssertEqual(
            UpNext.currentEpisode(media: show, videoID: custom.id, episode: custom)?.episode, 2)
        XCTAssertEqual(
            UpNext.currentEpisode(media: show, videoID: "tt123:2:3")?.season, 2)
        XCTAssertNil(UpNext.currentEpisode(media: show, videoID: "unrelated:2:3"))
        XCTAssertNil(UpNext.currentEpisode(media: show, videoID: "tt123:1:0"))
        XCTAssertNil(UpNext.currentEpisode(media: show, videoID: "custom-file"))
        let movie = MediaItem(id: "tt123", type: "movie", name: "Movie")
        XCTAssertNil(UpNext.currentEpisode(media: movie, videoID: "tt123:1:1"))
    }

    func testCancelledOrFailedSeasonFetchCannotSuggestAnUnverifiedEpisode() async throws {
        enum Failure: Error { case unavailable }
        do {
            _ = try await UpNext.resolve(
                after: episode(1), seasons: [1, 2], isWatched: { _ in false },
                fetchSeason: { _ in throw Failure.unavailable })
            XCTFail("A failed season cannot be skipped")
        } catch Failure.unavailable {}
        let task = Task {
            try await UpNext.resolve(
                after: self.episode(1), seasons: [1], isWatched: { _ in false }
            ) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return [self.episode(2)]
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must reject late metadata")
        } catch is CancellationError {}
    }

    func testHomeUsesLatestShowActivityAndDeduplicatesAliases() {
        var enriched = show
        enriched.tmdbID = 42
        let alternate = MediaItem(id: "tmdb:tv:42", type: "series", name: "Show")
        var history = WatchProgress()
        history.setWatched(true, for: enriched, episode: episode(1), now: now)
        history.setWatched(true, for: alternate, episode: episode(2), now: now.addingTimeInterval(1))
        let seeds = UpNext.homeSeeds(in: history)
        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds.first?.episode.episode, 2)
        history.setWatched(false, for: enriched, episode: episode(3), now: now.addingTimeInterval(2))
        XCTAssertTrue(UpNext.homeSeeds(in: history).isEmpty)
        history.setWatched(true, for: enriched, now: now.addingTimeInterval(3))
        XCTAssertTrue(UpNext.homeSeeds(in: history).isEmpty)
    }

    func testImportedWatchedEpisodesCanPopulateHomeWithoutInventedProgress() {
        var history = WatchProgress()
        history.mergeTrakt([
            .init(media: show, videoID: "tt123:1:4", watchedAt: now),
            .init(media: MediaItem(id: "tt456", type: "movie", name: "Movie"), videoID: nil, watchedAt: now),
        ])
        XCTAssertEqual(UpNext.homeSeeds(in: history).first?.episode.episode, 4)
        XCTAssertEqual(UpNext.homeSeeds(in: history).count, 1)
        XCTAssertTrue(UpNext.homeSeeds(in: history, limit: 0).isEmpty)
        XCTAssertTrue(history.continueWatching.isEmpty)
    }

    func testUnfinishedEpisodeKeepsItsPlaceInContinueWatchingInsteadOfAdvancingHome() {
        var history = WatchProgress()
        history.setWatched(true, for: show, episode: episode(1), now: now)
        history.record(
            media: show, videoID: "tt123:1:2", subtitle: nil, elapsed: 100, duration: 1000,
            now: now.addingTimeInterval(1))
        XCTAssertTrue(UpNext.homeSeeds(in: history).isEmpty)
        XCTAssertEqual(history.continueWatching.count, 1)
        history.record(
            media: show, videoID: "tt123:1:2", subtitle: nil, elapsed: 1000, duration: 1000,
            ended: true, now: now.addingTimeInterval(2))
        XCTAssertEqual(UpNext.homeSeeds(in: history).first?.episode.episode, 2)
    }

    func testOfferAppearsInLastThirtySecondsWithoutTreatingLiveOrOpeningFramesAsAnEnding() {
        XCTAssertFalse(
            UpNext.shouldOffer(timeline: .init(elapsed: 1, duration: 0, isSeekable: false), ended: false))
        XCTAssertFalse(
            UpNext.shouldOffer(timeline: .init(elapsed: 1969, duration: 2000, isSeekable: true), ended: false)
        )
        XCTAssertTrue(
            UpNext.shouldOffer(timeline: .init(elapsed: 1970, duration: 2000, isSeekable: true), ended: false)
        )
        XCTAssertFalse(
            UpNext.shouldOffer(timeline: .init(elapsed: 30, duration: 60, isSeekable: true), ended: false))
        XCTAssertTrue(
            UpNext.shouldOffer(timeline: .init(elapsed: 57, duration: 60, isSeekable: true), ended: false))
        XCTAssertTrue(
            UpNext.shouldOffer(timeline: .init(elapsed: 10, duration: 0, isSeekable: false), ended: true))
    }
}
