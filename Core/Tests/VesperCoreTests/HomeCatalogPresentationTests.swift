import XCTest
@testable import VesperCore

@MainActor
final class HomeCatalogPresentationTests: XCTestCase {
    private let movies = HomeCatalog.tmdb(.popularMovies).id
    private let shows = HomeCatalog.tmdb(.popularSeries).id

    private func item(_ id: String, type: String = "movie") -> MediaItem {
        var media = MediaItem(id: id, type: type, name: id)
        media.poster = "https://images.example/\(id).jpg"
        return media
    }

    private func load(_ results: [String: [MediaItem]], failing: Set<String> = []) async -> HomeFeedController
    {
        let home = HomeFeedController()
        await home.load(catalogs: TMDBCatalog.allCases.map(HomeCatalog.tmdb)) { catalog in
            ContentSource(initialCacheID: catalog.id) { _ in
                if failing.contains(catalog.id) { throw URLError(.notConnectedToInternet) }
                return ContentPage(items: results[catalog.id] ?? [], cacheID: catalog.id)
            }
        }
        return home
    }

    private func presentation(
        _ home: HomeFeedController, preferences: CatalogPreferences = .init(),
        configured: Bool = true, heroID: String = HeroCatalogSelection.automaticID,
        settled: Set<String>? = nil, loading: Bool? = nil
    ) -> HomeCatalogPresentation {
        HomeCatalogPresentation(
            addons: [], tmdbConfigured: configured, preferences: preferences,
            feeds: home.feeds, tmdbFeeds: home.tmdbFeeds,
            settledCatalogIDs: settled ?? home.settledCatalogIDs,
            isLoading: loading ?? home.isLoading, heroID: heroID)
    }

    func testRowsPrefetchAndHeroShareTheSameMixedGroupOrderingAndLimit() async throws {
        let home = await load([
            movies: (1...35).map { item("m\($0)") },
            shows: (1...35).map { item("s\($0)", type: "series") },
        ])
        let group = CombinedCatalog(name: "Together", members: [shows, movies])
        let preferences = CatalogPreferences(order: [group.id], groups: [group])
        let snapshot = presentation(home, preferences: preferences)
        let row = try XCTUnwrap(snapshot.rows.first)
        XCTAssertEqual(row.id, group.id)
        XCTAssertEqual(row.items.prefix(4).map(\.id), ["s1", "m1", "s2", "m2"])
        XCTAssertEqual(row.items.count, 20)
        XCTAssertFalse(snapshot.rows.contains { [movies, shows].contains($0.id) })
        XCTAssertEqual(snapshot.prefetchRows.first?.items.map(\.key), row.items.map(\.key))
        XCTAssertEqual(snapshot.heroItems.map(\.key), row.items.map(\.key))
        XCTAssertEqual(snapshot.heroCatalogs.first?.id, group.id)
    }

    func testHiddenGroupRemainsAvailableForExplicitHeroButSuppressesSourceRows() async {
        let home = await load([movies: [item("m1")], shows: [item("s1", type: "series")]])
        let group = CombinedCatalog(name: "Hidden", members: [movies, shows])
        let preferences = CatalogPreferences(
            customizations: [group.id: .init(isHidden: true)], groups: [group])
        let automatic = presentation(home, preferences: preferences)
        XCTAssertTrue(automatic.heroItems.isEmpty)
        XCTAssertFalse(automatic.rows.contains { [movies, shows, group.id].contains($0.id) })
        XCTAssertTrue(automatic.heroCatalogs.contains { $0.id == group.id })
        let explicit = presentation(home, preferences: preferences, heroID: group.id)
        XCTAssertEqual(explicit.heroItems.map(\.id), ["m1", "s1"])
    }

    func testGroupWaitsForItsMembersWhileUnrelatedLoadingDoesNotBlockIt() async throws {
        let home = await load([movies: [item("m1")], shows: [item("s1", type: "series")]])
        let group = CombinedCatalog(name: "Together", members: [movies, shows])
        let preferences = CatalogPreferences(groups: [group])
        let pending = presentation(home, preferences: preferences, settled: [movies], loading: true)
        let waiting = try XCTUnwrap(pending.rows.first { $0.id == group.id })
        XCTAssertTrue(waiting.isLoading)
        XCTAssertTrue(waiting.items.isEmpty)
        let partial = presentation(home, preferences: preferences, settled: [movies, shows], loading: true)
        let ready = try XCTUnwrap(partial.rows.first { $0.id == group.id })
        XCTAssertFalse(ready.isLoading)
        XCTAssertEqual(ready.items.map(\.id), ["m1", "s1"])
    }

    func testFailureKeepsSuccessfulMemberAndUnavailableGroupHasEditState() async throws {
        let home = await load([movies: [item("m1")]], failing: [shows])
        let group = CombinedCatalog(name: "Together", members: [movies, shows])
        let preferences = CatalogPreferences(groups: [group])
        let failed = presentation(home, preferences: preferences)
        let row = try XCTUnwrap(failed.rows.first { $0.id == group.id })
        XCTAssertEqual(row.items.map(\.id), ["m1"])
        XCTAssertNotNil(row.error)
        XCTAssertFalse(row.isLoading)
        let unavailable = presentation(home, preferences: preferences, configured: false)
        XCTAssertEqual(unavailable.rows.count, 1)
        XCTAssertTrue(unavailable.rows[0].isUnavailable)
        XCTAssertTrue(unavailable.rows[0].items.isEmpty)
        XCTAssertFalse(unavailable.rows[0].isLoading)
        XCTAssertEqual(unavailable.catalogs.count, TMDBCatalog.allCases.count + 1)
    }

    func testSnapshotRetainsContentWhileFreshSnapshotReflectsRenamesAndDeletion() async {
        let home = await load([movies: [item("m1")], shows: [item("s1", type: "series")]])
        let group = CombinedCatalog(name: "Together", members: [movies, shows])
        var preferences = CatalogPreferences(order: [group.id], groups: [group])
        let original = presentation(home, preferences: preferences)
        preferences.groups[0].name = "Renamed"
        let renamed = presentation(home, preferences: preferences)
        XCTAssertEqual(original.rows.first?.title, "Together")
        XCTAssertEqual(renamed.rows.first?.title, "Renamed")
        let restored = presentation(home)
        XCTAssertEqual(restored.rows.prefix(2).map(\.id), [movies, shows])
        XCTAssertEqual(original.rows.first?.items.map(\.id), ["m1", "s1"])
    }

    func testFeedRevisionInvalidatesPresentationAfterLoadRefreshAndCancel() async {
        let home = HomeFeedController()
        let initial = home.presentationRevision
        var updated = false
        await home.load(catalogs: [.tmdb(.popularMovies)]) { _ in
            ContentSource(initialCacheID: "movie") { _ in
                ContentPage(items: [self.item(updated ? "new" : "old")], cacheID: "movie")
            }
        }
        let loaded = home.presentationRevision
        XCTAssertNotEqual(initial, loaded)
        let original = presentation(home)
        home.refresh(cacheIDs: ["unrelated"])
        await home.flushUpdates()
        XCTAssertEqual(home.presentationRevision, loaded)
        updated = true
        home.refresh(cacheIDs: ["movie"])
        await home.flushUpdates()
        XCTAssertNotEqual(home.presentationRevision, loaded)
        XCTAssertEqual(presentation(home).rows.first?.items.first?.id, "new")
        XCTAssertEqual(original.rows.first?.items.first?.id, "old")
        let refreshed = home.presentationRevision
        home.cancel()
        XCTAssertNotEqual(home.presentationRevision, refreshed)
    }
}
