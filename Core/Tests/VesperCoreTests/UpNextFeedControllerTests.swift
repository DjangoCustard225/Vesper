import XCTest
@testable import VesperCore

@MainActor final class UpNextFeedControllerTests: XCTestCase {
    private func seeds(_ count: Int = 4) -> [UpNext.Seed] {
        var history = WatchProgress()
        history.mergeTrakt(
            (1...count).map {
                TraktWatchedEntry(
                    media: MediaItem(id: "tt\($0)", type: "series", name: "Show \($0)"),
                    videoID: "tt\($0):1:1", watchedAt: Date(timeIntervalSince1970: Double($0)))
            })
        return UpNext.homeSeeds(in: history)
    }

    func testConcurrentLoadsPreserveRecencyAndIsolateProviderFailure() async {
        enum Failure: Error { case unavailable }
        let feed = UpNextFeedController(), seeds = seeds()
        var active = 0, maximum = 0
        await feed.load(seeds) { seed in
            active += 1
            maximum = max(maximum, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(seed.media.id == "tt4" ? 30 : 1))
            if seed.media.id == "tt2" { throw Failure.unavailable }
            return .init(media: seed.media, episode: seed.episode)
        }
        XCTAssertEqual(feed.items.map(\.media.id), ["tt4", "tt3", "tt1"])
        XCTAssertLessThanOrEqual(maximum, 3)
    }

    func testLateNonCooperativeResponseCannotRestoreRemovedRecommendations() async {
        let feed = UpNextFeedController(), seeds = seeds(1)
        var continuation: CheckedContinuation<Void, Never>?
        let old = Task {
            await feed.load(seeds) { seed in
                await withCheckedContinuation { continuation = $0 }
                return .init(media: seed.media, episode: seed.episode)
            }
        }
        while continuation == nil { await Task.yield() }
        await feed.load([]) { _ in
            XCTFail("Empty history must not fetch metadata"); return nil
        }
        continuation?.resume()
        await old.value
        XCTAssertTrue(feed.items.isEmpty)
    }

    func testLeavingHomeRejectsAnInFlightResult() async {
        let feed = UpNextFeedController(), seeds = seeds(1)
        await feed.load(seeds) { seed in
            feed.cancel()
            return .init(media: seed.media, episode: seed.episode)
        }
        XCTAssertTrue(feed.items.isEmpty)
    }

    func testRefreshKeepsExistingCardsAndPublishesTheNewRowTogether() async {
        let feed = UpNextFeedController(), seeds = seeds()
        await feed.load(seeds) { .init(media: $0.media, episode: $0.episode) }
        let previous = feed.items.map(\.id)
        await feed.load(seeds) { seed in
            XCTAssertEqual(feed.items.map(\.id), previous)
            await Task.yield()
            return seed.media.id == "tt2" ? nil : .init(media: seed.media, episode: seed.episode)
        }
        XCTAssertEqual(feed.items.map(\.media.id), ["tt4", "tt3", "tt1"])
    }

    func testTemporaryRefreshFailurePreservesMatchingCardsButNotRemovedShows() async {
        enum Failure: Error { case unavailable }
        let feed = UpNextFeedController(), seeds = seeds()
        await feed.load(seeds) { .init(media: $0.media, episode: $0.episode) }
        let remaining = Array(seeds.prefix(2))
        await feed.load(remaining) { _ in
            XCTAssertEqual(feed.items.map(\.media.id), ["tt4", "tt3"])
            throw Failure.unavailable
        }
        XCTAssertEqual(feed.items.map(\.media.id), ["tt4", "tt3"])
    }

    func testCredentialChangeCannotRetainThePreviousProvidersCards() async {
        enum Failure: Error { case unavailable }
        let feed = UpNextFeedController(), seeds = seeds(1)
        await feed.load(seeds, context: "first") { .init(media: $0.media, episode: $0.episode) }
        await feed.load(seeds, context: "second") { _ in
            XCTAssertTrue(feed.items.isEmpty)
            throw Failure.unavailable
        }
        XCTAssertTrue(feed.items.isEmpty)
    }
}
