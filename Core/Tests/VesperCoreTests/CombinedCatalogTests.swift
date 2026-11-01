import XCTest
@testable import VesperCore

@MainActor
private final class CombinedFixture {
    var calls: [String: [Int]] = [:]
    var failures: Set<String> = []
    var pages: [String: [Int: ContentPage]] = [:]

    func source(_ id: String) -> CombinedCatalogSource {
        CombinedCatalogSource(
            id: id, title: id,
            source: ContentSource { cursor in
                self.calls[id, default: []].append(cursor)
                if self.failures.contains(id) { throw URLError(.notConnectedToInternet) }
                return self.pages[id]?[cursor] ?? ContentPage(items: [])
            })
    }
}

private actor CombinedGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var arrived = false
    func wait() async {
        arrived = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}

@MainActor
final class CombinedCatalogTests: XCTestCase {
    private func item(_ id: String, type: String = "movie") -> MediaItem {
        MediaItem(id: id, type: type, name: id)
    }

    private func page(_ ids: [String], next: Int? = nil, cacheID: String? = nil) -> ContentPage {
        ContentPage(items: ids.map { item($0) }, nextCursor: next, cacheID: cacheID)
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true")
    }

    func testLegacyPreferencesDecodeWithoutGroupsAndGroupsRoundTrip() throws {
        let legacy = Data(#"{"order":["tmdb:popularMovies"],"customizations":{}}"#.utf8)
        var preferences = try JSONDecoder().decode(CatalogPreferences.self, from: legacy)
        XCTAssertTrue(preferences.groups.isEmpty)
        let group = CombinedCatalog(name: "Favorites", members: ["a", "a", "b", "group:nested"])
        XCTAssertEqual(group.members, ["a", "b"])
        preferences.groups = [group]
        preferences.customizations[group.id] = .init(isHidden: true)
        XCTAssertEqual(
            try JSONDecoder().decode(CatalogPreferences.self, from: JSONEncoder().encode(preferences)),
            preferences)
    }

    func testGroupsSuppressOriginalsWithoutChangingVisibilityAndDeletingRestoresIt() {
        let sources = TMDBCatalog.allCases.map(HomeCatalog.tmdb)
        let group = CombinedCatalog(name: "Mixed", members: Array(sources.prefix(2).map(\.id)))
        var preferences = CatalogPreferences(
            customizations: [sources[0].id: .init(isHidden: true)], groups: [group])
        let catalogs = sources + [.combined(group)]
        XCTAssertFalse(preferences.isVisible(sources[0]))
        XCTAssertFalse(preferences.isVisible(sources[1]))
        XCTAssertTrue(preferences.isVisible(.combined(group)))
        preferences.customizations[group.id] = .init(isHidden: true)
        XCTAssertFalse(
            preferences.requested(catalogs, heroID: "automatic").contains { group.members.contains($0.id) })
        XCTAssertEqual(
            Set(preferences.requested(catalogs, heroID: group.id).map(\.id)), Set(sources.map(\.id)))
        preferences.groups = []
        XCTAssertFalse(preferences.isVisible(sources[0]))
        XCTAssertTrue(preferences.isVisible(sources[1]))
    }

    func testSharedMembersRequestedOnceAndMembershipSurvivesUnavailableSources() {
        let sources = TMDBCatalog.allCases.map(HomeCatalog.tmdb)
        let first = CombinedCatalog(name: "First", members: [sources[0].id, sources[1].id, "unavailable"])
        let second = CombinedCatalog(name: "Second", members: [sources[1].id, sources[2].id])
        var preferences = CatalogPreferences(order: [second.id, first.id], groups: [first, second])
        let catalogs = sources + [.combined(first), .combined(second)]
        let requested = preferences.requested(catalogs, heroID: "automatic")
        XCTAssertEqual(requested.count, sources.count)
        XCTAssertEqual(Set(requested.map(\.id)).count, requested.count)
        XCTAssertEqual(preferences.ordered(catalogs).prefix(2).map(\.id), [second.id, first.id])
        XCTAssertEqual(preferences.members(of: first, in: sources).map(\.id), [sources[0].id, sources[1].id])
        preferences.groups.removeFirst()
        XCTAssertFalse(preferences.isVisible(sources[1]))
        XCTAssertTrue(preferences.isVisible(sources[0]))
        XCTAssertEqual(first.members.last, "unavailable")
        preferences = CatalogPreferences()
        XCTAssertTrue(sources.allSatisfy(preferences.isVisible))
    }

    func testAlternationUsesIdentityAliasesButKeepsMoviesAndShowsDistinct() {
        var alias = item("tmdb:movie:1")
        alias.imdbID = "tt1"
        let result = CombinedCatalog.alternating([
            [item("tt1"), item("tt2"), item("tt3")],
            [alias, item("tt1", type: "series")],
        ])
        XCTAssertEqual(result.map(\.id), ["tt1", "tt2", "tt1", "tt3"])
        XCTAssertEqual(result[0].tmdbID, 1)
        XCTAssertEqual(result[2].type, "series")
        XCTAssertEqual(CombinedCatalog.alternating([]).count, 0)
    }

    func testPaginationAppendsSettledRoundsAndTracksUnequalPagesIndependently() async {
        let fixture = CombinedFixture(), model = CombinedCatalogController()
        fixture.pages = [
            "a": [1: page(["a1", "a2", "a3"], next: 2), 2: page(["a4"])],
            "b": [1: page(["b1"], next: 20), 20: page(["b2", "b3"])],
        ]
        await model.load([fixture.source("a"), fixture.source("b"), fixture.source("a")])
        XCTAssertEqual(model.items.map(\.id), ["a1", "b1", "a2", "a3"])
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["a1", "b1", "a2", "a3", "a4", "b2", "b3"])
        XCTAssertEqual(fixture.calls["a"], [1, 2])
        XCTAssertEqual(fixture.calls["b"], [1, 20])
        XCTAssertFalse(model.hasMore)
    }

    func testDuplicatesAcrossSourcesDoNotStopMemberPagination() async {
        let fixture = CombinedFixture(), model = CombinedCatalogController()
        fixture.pages = [
            "a": [1: page(["shared", "next"])],
            "b": [1: page(["shared"], next: 2), 2: page(["next"], next: 3), 3: page(["last"])],
        ]
        await model.load([fixture.source("a"), fixture.source("b")])
        await model.loadMore()
        XCTAssertTrue(model.hasMore)
        XCTAssertEqual(model.items.map(\.id), ["shared", "next"])
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["shared", "next", "last"])
        XCTAssertFalse(model.hasMore)
    }

    func testRepeatedPagesAndCursorLoopsExhaustOnlyTheirSource() async {
        let fixture = CombinedFixture(), model = CombinedCatalogController()
        fixture.pages = [
            "a": [1: page(["repeat"], next: 2), 2: page(["repeat"], next: 3)],
            "b": [1: page(["b1"], next: 2), 2: page(["b2"], next: 1)],
        ]
        await model.load([fixture.source("a"), fixture.source("b")])
        await model.loadMore()
        XCTAssertFalse(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(fixture.calls["a"], [1, 2])
        XCTAssertEqual(fixture.calls["b"], [1, 2])
    }

    func testPartialFailureDoesNotBlockHealthyPagesAndRetriesOnlyFailedCursor() async {
        let fixture = CombinedFixture(), model = CombinedCatalogController()
        fixture.pages = ["a": [1: page(["a1"], next: 2), 2: page(["a2"])], "b": [1: page(["b1"])]]
        fixture.failures = ["b"]
        await model.load([fixture.source("a"), fixture.source("b")])
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["a1", "a2"])
        XCTAssertEqual(fixture.calls["b"], [1])
        fixture.failures = []
        await model.retry()
        XCTAssertEqual(model.items.map(\.id), ["a1", "a2", "b1"])
        XCTAssertNil(model.error)
        XCTAssertEqual(fixture.calls["a"], [1, 2])
        XCTAssertEqual(fixture.calls["b"], [1, 1])
    }

    func testFailedNextPageRetriesSameCursorAndRetainsEarlierRound() async {
        let fixture = CombinedFixture(), model = CombinedCatalogController()
        fixture.pages = ["a": [1: page(["a1"], next: 2), 2: page(["a2"])]]
        await model.load([fixture.source("a")])
        fixture.failures = ["a"]
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["a1"])
        XCTAssertFalse(model.hasMore)
        fixture.failures = []
        await model.retry()
        XCTAssertEqual(fixture.calls["a"], [1, 2, 2])
        XCTAssertEqual(model.items.map(\.id), ["a1", "a2"])
    }

    func testTargetedRevalidationRetainsLaterPagesAndUnrelatedProviders() async {
        let fixture = CombinedFixture(), model = CombinedCatalogController()
        fixture.pages = [
            "a": [1: page(["a1"], next: 2, cacheID: "a1"), 2: page(["a2"], cacheID: "a2")],
            "b": [1: page(["b1"], cacheID: "b1")],
        ]
        await model.load([fixture.source("a"), fixture.source("b")])
        await model.loadMore()
        fixture.pages["a"]?[1] = page(["updated"], next: 2, cacheID: "a1")
        model.refresh(cacheIDs: ["a1", "unrelated"])
        await waitUntil { !model.loading }
        XCTAssertEqual(model.items.map(\.id), ["updated", "b1", "a2"])
        XCTAssertEqual(fixture.calls["a"], [1, 2, 1])
        XCTAssertEqual(fixture.calls["b"], [1])
        fixture.failures = ["a"]
        model.refresh(cacheIDs: ["a1"])
        await waitUntil { !model.loading }
        XCTAssertEqual(model.items.map(\.id), ["updated", "b1", "a2"])
        XCTAssertNil(model.error)
    }

    func testOldNonCooperativeLoadCannotReplaceNewMembershipOrFilters() async {
        let model = CombinedCatalogController(), gate = CombinedGate()
        let pending = Task {
            await model.load([
                CombinedCatalogSource(
                    id: "a", title: "a",
                    source: ContentSource { _ in
                        await gate.wait()
                        return self.page(["old"])
                    })
            ])
        }
        await waitUntil { await gate.arrived }
        await model.load([
            CombinedCatalogSource(id: "b", title: "b", source: ContentSource { _ in self.page(["new"]) })
        ])
        await gate.open()
        await pending.value
        XCTAssertEqual(model.items.map(\.id), ["new"])
        XCTAssertFalse(model.loading)
    }

    func testCancelDropsPendingCacheUpdatesAndLateResults() async {
        let model = CombinedCatalogController(), gate = CombinedGate()
        let pending = Task {
            await model.load([
                CombinedCatalogSource(
                    id: "a", title: "a",
                    source: ContentSource { _ in
                        await gate.wait()
                        return self.page(["old"], cacheID: "a1")
                    })
            ])
        }
        await waitUntil { await gate.arrived }
        model.refresh(cacheIDs: ["a1"])
        model.cancel()
        await gate.open()
        await pending.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.loading)
    }
}
