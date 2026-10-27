import XCTest
@testable import VesperCore

final class ArtworkPrefetchTests: XCTestCase {
    private var items: [MediaItem] {
        (0..<12).map {
            MediaItem(
                id: String($0), type: "movie", name: String($0),
                poster: "https://images.example/original/\($0).jpg")
        }
    }

    func testPreloadsOnlyOneScreenfulAhead() {
        let keys = Set(items[3...5].map(\.key))
        let urls = ArtworkPrefetchWindow.urls(items: items, visibleKeys: keys)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["6.jpg", "7.jpg", "8.jpg"])
        XCTAssertTrue(urls.allSatisfy { $0.path.contains("/original/") })
    }

    func testReverseScrollingPreloadsPreviousScreenful() {
        let urls = ArtworkPrefetchWindow.urls(
            items: items, visibleKeys: Set(items[3...5].map(\.key)), forward: false)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["2.jpg", "1.jpg", "0.jpg"])
    }

    func testHiddenReplacedAndEndOfCatalogWindowsDoNotFetch() {
        XCTAssertTrue(ArtworkPrefetchWindow.urls(items: items, visibleKeys: []).isEmpty)
        XCTAssertTrue(ArtworkPrefetchWindow.urls(items: [], visibleKeys: ["old"]).isEmpty)
        XCTAssertTrue(ArtworkPrefetchWindow.urls(items: items, visibleKeys: [items.last!.key]).isEmpty)
        XCTAssertTrue(
            ArtworkPrefetchWindow.urls(items: items, visibleKeys: [items.first!.key], forward: false).isEmpty)
    }

    func testInvalidAndDuplicateArtworkURLsAreSkipped() {
        var values = items
        values[3].poster = "file:///tmp/image.jpg"
        values[4].poster = values[5].poster
        let urls = ArtworkPrefetchWindow.urls(items: values, visibleKeys: Set(values[0...2].map(\.key)))
        XCTAssertEqual(urls.map(\.lastPathComponent), ["5.jpg"])
    }

    func testHomeWarmsOnlyTheFirstScreenOfTheApproachingPopulatedRow() {
        let rows: [ArtworkPrefetchWindow.Row] = [
            .init(id: "first", items: Array(items[0...3])),
            .init(id: "empty", items: []),
            .init(id: "second", items: Array(items[4...7])),
            .init(id: "third", items: Array(items[8...11])),
        ]
        XCTAssertEqual(
            ArtworkPrefetchWindow.urls(rows: rows, visibleRows: [], posterCount: 2).map(\.lastPathComponent),
            ["0.jpg", "1.jpg"])
        XCTAssertEqual(
            ArtworkPrefetchWindow.urls(rows: rows, visibleRows: ["first"], posterCount: 2).map(
                \.lastPathComponent),
            ["4.jpg", "5.jpg"])
        XCTAssertEqual(
            ArtworkPrefetchWindow.urls(rows: rows, visibleRows: ["first", "second"], posterCount: 2).map(
                \.lastPathComponent),
            ["8.jpg", "9.jpg"])
        XCTAssertEqual(
            ArtworkPrefetchWindow.urls(rows: rows, visibleRows: ["third"], forward: false, posterCount: 2)
                .map(\.lastPathComponent),
            ["4.jpg", "5.jpg"])
        XCTAssertTrue(ArtworkPrefetchWindow.urls(rows: rows, visibleRows: ["third"], posterCount: 2).isEmpty)
        XCTAssertTrue(
            ArtworkPrefetchWindow.urls(rows: rows, visibleRows: ["first"], forward: false, posterCount: 2)
                .isEmpty)
        XCTAssertTrue(ArtworkPrefetchWindow.urls(rows: rows, visibleRows: [], posterCount: 0).isEmpty)
    }

    func testHomeRejectsUnsafeURLsAndDoesNotRequestDuplicates() {
        var values = items
        values[0].poster = "file:///tmp/private.jpg"
        values[1].poster = values[2].poster
        let rows = [ArtworkPrefetchWindow.Row(id: "only", items: values)]
        let urls = ArtworkPrefetchWindow.urls(rows: rows, visibleRows: [], posterCount: 3)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["2.jpg"])
        XCTAssertTrue(urls.allSatisfy { $0.path.contains("/original/") })
    }
}
