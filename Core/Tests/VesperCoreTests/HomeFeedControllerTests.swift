import XCTest
@testable import VesperCore

@MainActor
private final class FeedGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private let started = XCTestExpectation(description: "Feed request suspended")
    private var released = false

    func suspend() async {
        started.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        let result = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(result, .completed)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class HomeFeedControllerTests: XCTestCase {
    private func addon() throws -> InstalledAddon {
        let data = Data(
            #"{"id":"test","name":"Provider","version":"1","resources":["catalog"],"types":["movie"],"catalogs":[{"id":"first","type":"movie"},{"id":"second","type":"movie"}]}"#
                .utf8)
        return InstalledAddon(
            manifestURL: try XCTUnwrap(URL(string: "https://example.com/manifest.json")),
            manifest: try JSONDecoder().decode(AddonManifest.self, from: data))
    }

    private func item(_ name: String) -> MediaItem { MediaItem(id: name, type: "movie", name: name) }

    func testFeedsKeepManifestOrderAndDeliverIndependently() async throws {
        let controller = HomeFeedController(), gate = FeedGate()
        let addon = try addon()
        let secondFinished = expectation(description: "Second shelf finishes independently")
        let task = Task {
            await controller.load(addons: [addon], includeTMDB: false) { catalog in
                ContentSource { _ in
                    guard case .addon(let feed) = catalog else { return ContentPage(items: []) }
                    if feed.catalog.id == "first" { await gate.suspend() } else { secondFinished.fulfill() }
                    return ContentPage(items: [self.item(feed.catalog.id)], cacheID: feed.catalog.id)
                }
            }
        }
        await gate.waitUntilStarted()
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertEqual(controller.feeds.map(\.catalog.id), ["first", "second"])
        XCTAssertTrue(controller.isLoading)
        gate.release()
        await task.value
        XCTAssertEqual(controller.feeds.map { $0.items.first?.id }, ["first", "second"])
        XCTAssertFalse(controller.isLoading)
    }

    func testCacheRefreshFetchesOnlyAffectedShelf() async throws {
        let controller = HomeFeedController()
        var counts: [String: Int] = [:]
        await controller.load(addons: [try addon()], includeTMDB: true) { catalog in
            let key: String
            switch catalog {
            case .addon(let feed): key = feed.catalog.id
            case .tmdb(let catalog): key = catalog.id
            }
            return ContentSource { _ in
                counts[key, default: 0] += 1
                return ContentPage(items: [self.item("\(key)-\(counts[key, default: 0])")], cacheID: key)
            }
        }
        controller.refresh(cacheIDs: ["second", "unknown"])
        await controller.flushUpdates()
        XCTAssertEqual(counts["second"], 2)
        XCTAssertEqual(counts["first"], 1)
        XCTAssertEqual(controller.feeds.last?.items.first?.id, "second-2")
        XCTAssertTrue(controller.tmdbFeeds.allSatisfy { counts[$0.id] == 1 })
    }

    func testUpdatesDuringInitialLoadAreReplayed() async throws {
        let controller = HomeFeedController(), gate = FeedGate()
        var calls = 0
        let task = Task {
            await controller.load(addons: [], includeTMDB: true) { catalog in
                ContentSource { _ in
                    guard case .tmdb(.popularMovies) = catalog else { return ContentPage(items: []) }
                    calls += 1
                    if calls == 1 { await gate.suspend() }
                    return ContentPage(items: [self.item("version-\(calls)")], cacheID: "popular")
                }
            }
        }
        await gate.waitUntilStarted()
        controller.refresh(cacheIDs: ["popular"])
        gate.release()
        await task.value
        await controller.flushUpdates()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(controller.tmdbFeeds.first?.items.first?.id, "version-2")
    }

    func testSupersededNonCooperativeRequestCannotRestoreRemovedFeeds() async {
        let controller = HomeFeedController(), gate = FeedGate()
        let old = Task {
            await controller.load(addons: [], includeTMDB: true) { catalog in
                ContentSource { _ in
                    if case .tmdb(.popularMovies) = catalog { await gate.suspend() }
                    return ContentPage(items: [self.item("obsolete")])
                }
            }
        }
        await gate.waitUntilStarted()
        await controller.load(addons: [], includeTMDB: false) { _ in
            ContentSource { _ in ContentPage(items: []) }
        }
        gate.release()
        await old.value
        XCTAssertTrue(controller.tmdbFeeds.isEmpty)
        XCTAssertFalse(controller.isLoading)
    }

    func testFailedReloadKeepsLoadedItemsAndReportsError() async {
        let controller = HomeFeedController()
        await controller.load(addons: [], includeTMDB: true) { _ in
            ContentSource { _ in ContentPage(items: [self.item("saved")]) }
        }
        await controller.load(addons: [], includeTMDB: true) { _ in
            ContentSource { _ in throw URLError(.notConnectedToInternet) }
        }
        XCTAssertTrue(controller.tmdbFeeds.allSatisfy { $0.items.first?.id == "saved" && $0.error != nil })
    }

    func testKnownCacheUpdateCanRecoverInitiallyFailedShelf() async {
        let controller = HomeFeedController()
        var fail = true
        await controller.load(addons: [], includeTMDB: true) { catalog in
            ContentSource(initialCacheID: "known") { _ in
                if fail { throw URLError(.notConnectedToInternet) }
                return ContentPage(items: [self.item("recovered")])
            }
        }
        XCTAssertTrue(controller.tmdbFeeds.allSatisfy { $0.error != nil })
        fail = false
        controller.refresh(cacheIDs: ["known"])
        await controller.flushUpdates()
        XCTAssertTrue(
            controller.tmdbFeeds.allSatisfy { $0.items.first?.id == "recovered" && $0.error == nil })
    }

    func testDisabledAddonsDoNotCreateFeedRequests() async throws {
        let controller = HomeFeedController()
        var disabled = try addon()
        disabled.isEnabled = false
        await controller.load(addons: [disabled], includeTMDB: false) { _ in
            XCTFail("Disabled add-on created a request")
            return ContentSource { _ in ContentPage(items: []) }
        }
        XCTAssertTrue(controller.feeds.isEmpty)
        XCTAssertFalse(controller.isLoading)
    }

    func testUpdateArrivingDuringRevalidationRunsAfterCurrentRequest() async {
        let controller = HomeFeedController(), gate = FeedGate()
        var calls = 0
        await controller.load(addons: [], includeTMDB: true) { catalog in
            ContentSource { _ in
                guard case .tmdb(.popularMovies) = catalog else { return ContentPage(items: []) }
                calls += 1
                if calls == 2 { await gate.suspend() }
                return ContentPage(items: [self.item("version-\(calls)")], cacheID: "popular")
            }
        }
        controller.refresh(cacheIDs: ["popular"])
        await gate.waitUntilStarted()
        controller.refresh(cacheIDs: ["popular"])
        gate.release()
        await controller.flushUpdates()
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(controller.tmdbFeeds.first?.items.first?.id, "version-3")
    }

    func testFailedRevalidationKeepsVisibleItemsWithoutReplacingError() async {
        let controller = HomeFeedController()
        var fail = false
        await controller.load(addons: [], includeTMDB: true) { catalog in
            ContentSource { _ in
                if fail { throw URLError(.timedOut) }
                return ContentPage(items: [self.item("saved")], cacheID: "catalog")
            }
        }
        fail = true
        controller.refresh(cacheIDs: ["catalog"])
        await controller.flushUpdates()
        XCTAssertTrue(controller.tmdbFeeds.allSatisfy { $0.items.first?.id == "saved" && $0.error == nil })
    }

    func testParentCancellationReachesOwnedRequestAndResetsLoading() async {
        let controller = HomeFeedController()
        let started = expectation(description: "Request started")
        let cancelled = expectation(description: "Request cancelled")
        let task = Task {
            await controller.load(addons: [], includeTMDB: true) { catalog in
                ContentSource { _ in
                    guard case .tmdb(.popularMovies) = catalog else { return ContentPage(items: []) }
                    started.fulfill()
                    do { try await Task.sleep(for: .seconds(60)) } catch {
                        cancelled.fulfill()
                        throw error
                    }
                    return ContentPage(items: [])
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await task.value
        XCTAssertFalse(controller.isLoading)
        XCTAssertTrue(controller.tmdbFeeds.allSatisfy { $0.error == nil })
    }
}
