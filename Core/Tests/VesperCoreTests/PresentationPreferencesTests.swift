import XCTest
@testable import VesperCore

final class PresentationPreferencesTests: XCTestCase {
    private func item(_ id: Int) throws -> MediaItem {
        try JSONDecoder().decode(MediaItem.self, from: Data("""
        {"id":"tt\(id)","type":"movie","name":"Title \(id)"}
        """.utf8))
    }
    func testSelectedCatalogSuppliesHeroTitlesInCatalogOrder() throws {
        let catalogs = [HeroCatalog(id: "tmdb", title: "Movies", items: [try item(1)]),
                        HeroCatalog(id: "addon", title: "Series", items: [try item(3), try item(2)])]
        XCTAssertEqual(HeroCatalogSelection.items(preferredID: "addon", catalogs: catalogs).map(\.id), ["tt3", "tt2"])
    }
    func testEmptyOrUnavailableCatalogFallsBackToFirstPopulatedCatalog() throws {
        let catalogs = [HeroCatalog(id: "empty", title: "Empty", items: []),
                        HeroCatalog(id: "available", title: "Available", items: [try item(1)])]
        for selection in [HeroCatalogSelection.automaticID, "removed-addon", "empty"] {
            XCTAssertEqual(HeroCatalogSelection.items(preferredID: selection, catalogs: catalogs).map(\.id), ["tt1"])
        }
    }
    func testHeroDeduplicatesTitlesAndLimitsPagingToTwenty() throws {
        let titles = try (1...30).map(item)
        let catalogs = [HeroCatalog(id: "catalog", title: "Catalog", items: [titles[0], titles[0]] + titles)]
        let selected = HeroCatalogSelection.items(preferredID: "catalog", catalogs: catalogs)
        XCTAssertEqual(selected.count, 20)
        XCTAssertEqual(selected.map(\.id), (1...20).map { "tt\($0)" })
    }
    func testNoAvailableCatalogsProducesNoHeroPages() {
        XCTAssertTrue(HeroCatalogSelection.items(preferredID: "automatic", catalogs: []).isEmpty)
        XCTAssertTrue(HeroCatalogSelection.items(preferredID: "empty", catalogs: [HeroCatalog(id: "empty", title: "Empty", items: [])]).isEmpty)
    }
    func testPaginationPreservesOrderAndAppendsOnlyNewTitles() throws {
        let result = CatalogPagination(existing: [try item(1), try item(1), try item(2)],
            incoming: [try item(2), try item(3), try item(3), try item(4)], providerHasMore: true)
        XCTAssertEqual(result.items.map(\.id), ["tt1", "tt2", "tt3", "tt4"])
        XCTAssertTrue(result.hasMore)
    }
    func testAutomaticPaginationStopsForEmptyRepeatedAndFinalPages() throws {
        let existing = [try item(1)]
        XCTAssertFalse(CatalogPagination(existing: existing, incoming: [], providerHasMore: true).hasMore)
        XCTAssertFalse(CatalogPagination(existing: existing, incoming: existing, providerHasMore: true).hasMore)
        let final = CatalogPagination(existing: existing, incoming: [try item(2)], providerHasMore: false)
        XCTAssertFalse(final.hasMore)
        XCTAssertEqual(final.items.map(\.id), ["tt1", "tt2"])
    }
    func testFilteredSearchPagesCanAdvanceWithoutLosingExistingResults() throws {
        let existing = [try item(1)]
        let filteredPage = CatalogPagination(existing: existing, incoming: [], providerHasMore: true, allowEmptyPages: true)
        XCTAssertTrue(filteredPage.hasMore)
        XCTAssertEqual(filteredPage.items, existing)
        XCTAssertFalse(CatalogPagination(existing: existing, incoming: [], providerHasMore: false, allowEmptyPages: true).hasMore)
        XCTAssertFalse(CatalogPagination(existing: existing, incoming: existing, providerHasMore: true, allowEmptyPages: true).hasMore)
    }
}
