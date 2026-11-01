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
            await controller.load(catalogs: HomeCatalog.catalogs(addons: [addon], includeTMDB: false)) {
                catalog in
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
        await controller.load(catalogs: HomeCatalog.catalogs(addons: [try addon()], includeTMDB: true)) {
            catalog in
            let key: String
            switch catalog {
            case .addon(let feed): key = feed.catalog.id
            case .tmdb(let catalog): key = catalog.id
            case .combined: return nil
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
            await controller.load(catalogs: HomeCatalog.catalogs(addons: [], includeTMDB: true)) { catalog in
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
            await controller.load(catalogs: HomeCatalog.catalogs(addons: [], includeTMDB: true)) { catalog in
                ContentSource { _ in
                    if case .tmdb(.popularMovies) = catalog { await gate.suspend() }
                    return ContentPage(items: [self.item("obsolete")])
                }
            }
        }
        await gate.waitUntilStarted()
        await controller.load(catalogs: HomeCatalog.catalogs(addons: [], includeTMDB: false)) { _ in
            ContentSource { _ in ContentPage(items: []) }
        }
        gate.release()
        await old.value
        XCTAssertTrue(controller.tmdbFeeds.isEmpty)
        XCTAssertFalse(controller.isLoading)
    }

    func testFailedReloadKeepsLoadedItemsAndReportsError() async {
        let controller = HomeFeedController()
        await controller.load(catalogs: HomeCatalog.catalogs(addons: [], includeTMDB: true)) { _ in
            ContentSource { _ in ContentPage(items: [self.item("saved")]) }
        }
        await controller.load(catalogs: HomeCatalog.catalogs(addons: [], includeTMDB: true)) { _ in
            ContentSource { _ in throw URLError(.notConnectedToInternet) }
        }
        XCTAssertTrue(controller.tmdbFeeds.allSatisfy { $0.items.first?.id == "saved" && $0.error != nil })
    }

    func testKnownCacheUpdateCanRecoverInitiallyFailedShelf() async {
        let controller = HomeFeedController()
        var fail = true
        await controller.load(catalogs: HomeCatalog.catalogs(addons: [], includeTMDB: true)) { catalog in
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
        await controller.load(catalogs: HomeCatalog.catalogs(addons: [disabled], includeTMDB: false)) { _ in
            XCTFail("Disabled add-on created a request")
            return ContentSource { _ in ContentPage(items: []) }
        }
        XCTAssertTrue(controller.feeds.isEmpty)
        XCTAssertFalse(controller.isLoading)
    }

    func testUpdateArrivingDuringRevalidationRunsAfterCurrentRequest() async {
        let controller = HomeFeedController(), gate = FeedGate()
        var calls = 0
        await controller.load(catalogs: HomeCatalog.catalogs(addons: [], includeTMDB: true)) { catalog in
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
        await controller.load(catalogs: HomeCatalog.catalogs(addons: [], includeTMDB: true)) { catalog in
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

    func testChangingOneCatalogRefetchesOnlyItsSourceAndClearsOnlyItsOldItems() async throws {
        let controller = HomeFeedController(), gate = FeedGate()
        let catalogs = HomeCatalog.catalogs(addons: [try addon()], includeTMDB: false)
        var calls: [String: Int] = [:]
        await controller.load(catalogs: catalogs) { catalog in
            ContentSource(initialCacheID: catalog.id + ":default") { _ in
                calls[catalog.id, default: 0] += 1
                return ContentPage(items: [self.item("original")], cacheID: catalog.id + ":default")
            }
        }
        let task = Task {
            await controller.load(catalogs: catalogs, preservingUnchanged: true) { catalog in
                let key = catalog.id + (catalog.id == catalogs[0].id ? ":filtered" : ":default")
                return ContentSource(initialCacheID: key) { _ in
                    calls[catalog.id, default: 0] += 1
                    await gate.suspend()
                    return ContentPage(items: [self.item("filtered")], cacheID: key)
                }
            }
        }
        await gate.waitUntilStarted()
        XCTAssertTrue(controller.feeds[0].items.isEmpty)
        XCTAssertEqual(controller.feeds[1].items.first?.id, "original")
        gate.release()
        await task.value
        XCTAssertEqual(calls[catalogs[0].id], 2)
        XCTAssertEqual(calls[catalogs[1].id], 1)
        XCTAssertEqual(controller.feeds[0].items.first?.id, "filtered")
    }

    func testPresentationOnlyReloadAndHidingDoNotFetchUnchangedCatalogs() async throws {
        let controller = HomeFeedController()
        let catalogs = HomeCatalog.catalogs(addons: [try addon()], includeTMDB: false)
        var calls = 0
        func source(_ catalog: HomeCatalog) -> ContentSource {
            ContentSource(initialCacheID: catalog.id) { _ in
                calls += 1
                return ContentPage(items: [self.item(catalog.id)], cacheID: catalog.id)
            }
        }
        await controller.load(catalogs: catalogs, source: source)
        await controller.load(catalogs: catalogs.reversed(), preservingUnchanged: true, source: source)
        XCTAssertEqual(controller.feeds.map(\.catalog.id), ["second", "first"])
        XCTAssertEqual(calls, 2)
        await controller.load(catalogs: [catalogs[1]], preservingUnchanged: true, source: source)
        XCTAssertEqual(controller.feeds.map(\.catalog.id), ["second"])
        XCTAssertEqual(calls, 2)
    }

    func testKeepingAnUnchangedShelfPreservesItsPreviousRefreshError() async {
        let controller = HomeFeedController()
        let catalogs: [HomeCatalog] = [.tmdb(.popularMovies)]
        await controller.load(catalogs: catalogs) { _ in
            ContentSource(initialCacheID: "stable") { _ in
                ContentPage(items: [self.item("saved")], cacheID: "stable")
            }
        }
        await controller.load(catalogs: catalogs) { _ in
            ContentSource(initialCacheID: "stable") { _ in throw URLError(.timedOut) }
        }
        await controller.load(catalogs: catalogs, preservingUnchanged: true) { _ in
            ContentSource(initialCacheID: "stable") { _ in
                XCTFail("Unchanged completed shelf was refetched")
                return ContentPage(items: [])
            }
        }
        XCTAssertEqual(controller.tmdbFeeds.first?.items.first?.id, "saved")
        XCTAssertNotNil(controller.tmdbFeeds.first?.error)
    }

    func testOldFilteredResponseCannotReplaceNewSelection() async throws {
        let controller = HomeFeedController(), gate = FeedGate()
        let catalogs = Array(HomeCatalog.catalogs(addons: [try addon()], includeTMDB: false).prefix(1))
        let old = Task {
            await controller.load(catalogs: catalogs) { _ in
                ContentSource(initialCacheID: "old-filter") { _ in
                    await gate.suspend()
                    return ContentPage(items: [self.item("old")], cacheID: "old-filter")
                }
            }
        }
        await gate.waitUntilStarted()
        await controller.load(catalogs: catalogs, preservingUnchanged: true) { _ in
            ContentSource(initialCacheID: "new-filter") { _ in
                ContentPage(items: [self.item("new")], cacheID: "new-filter")
            }
        }
        gate.release()
        await old.value
        XCTAssertEqual(controller.feeds.first?.items.first?.id, "new")
        XCTAssertFalse(controller.isLoading)
    }

    func testParentCancellationReachesOwnedRequestAndResetsLoading() async {
        let controller = HomeFeedController()
        let started = expectation(description: "Request started")
        let cancelled = expectation(description: "Request cancelled")
        let task = Task {
            await controller.load(catalogs: HomeCatalog.catalogs(addons: [], includeTMDB: true)) { catalog in
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
    func testCombinedGroupsShareUnderlyingRequestsAndSettleBeforeUnrelatedShelf() async {
        let controller = HomeFeedController(), gate = FeedGate()
        let sources = TMDBCatalog.allCases.map(HomeCatalog.tmdb)
        let group = CombinedCatalog(name: "First", members: [sources[0].id, sources[1].id])
        let overlap = CombinedCatalog(name: "Second", members: [sources[1].id, sources[2].id])
        let preferences = CatalogPreferences(groups: [group, overlap])
        let requested = preferences.requested(
            sources + [.combined(group), .combined(overlap)], heroID: group.id)
        var calls: [String: Int] = [:]
        let task = Task {
            await controller.load(catalogs: requested) { catalog in
                ContentSource { _ in
                    calls[catalog.id, default: 0] += 1
                    if catalog.id == sources[3].id { await gate.suspend() }
                    return ContentPage(items: [self.item(catalog.id)], cacheID: catalog.id)
                }
            }
        }
        await gate.waitUntilStarted()
        for _ in 0..<500 {
            if Set(group.members).isSubset(of: controller.settledCatalogIDs) { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(Set(group.members).isSubset(of: controller.settledCatalogIDs))
        XCTAssertTrue(controller.isLoading)
        XCTAssertFalse(controller.settledCatalogIDs.contains(sources[3].id))
        gate.release()
        await task.value
        XCTAssertEqual(calls.count, sources.count)
        XCTAssertTrue(calls.values.allSatisfy { $0 == 1 })
        controller.cancel()
        XCTAssertTrue(controller.settledCatalogIDs.isEmpty)
    }

}
