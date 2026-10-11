import XCTest
@testable import VesperCore

final class ArtworkPrefetchTests: XCTestCase {
    private var items: [MediaItem] {
        (0..<12).map { MediaItem(id: String($0), type: "movie", name: String($0), poster: "https://images.example/original/\($0).jpg") }
    }
    func testPreloadsOnlyOneScreenfulAhead() {
        let keys = Set(items[3...5].map(\.key))
        let urls = ArtworkPrefetchWindow.urls(items: items, visibleKeys: keys)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["6.jpg", "7.jpg", "8.jpg"])
        XCTAssertTrue(urls.allSatisfy { $0.path.contains("/original/") })
    }
    func testReverseScrollingPreloadsPreviousScreenful() {
        let urls = ArtworkPrefetchWindow.urls(items: items, visibleKeys: Set(items[3...5].map(\.key)), forward: false)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["2.jpg", "1.jpg", "0.jpg"])
    }
    func testHiddenReplacedAndEndOfCatalogWindowsDoNotFetch() {
        XCTAssertTrue(ArtworkPrefetchWindow.urls(items: items, visibleKeys: []).isEmpty)
        XCTAssertTrue(ArtworkPrefetchWindow.urls(items: [], visibleKeys: ["old"]).isEmpty)
        XCTAssertTrue(ArtworkPrefetchWindow.urls(items: items, visibleKeys: [items.last!.key]).isEmpty)
        XCTAssertTrue(ArtworkPrefetchWindow.urls(items: items, visibleKeys: [items.first!.key], forward: false).isEmpty)
    }
    func testInvalidAndDuplicateArtworkURLsAreSkipped() {
        var values = items
        values[3].poster = "file:///tmp/image.jpg"
        values[4].poster = values[5].poster
        let urls = ArtworkPrefetchWindow.urls(items: values, visibleKeys: Set(values[0...2].map(\.key)))
        XCTAssertEqual(urls.map(\.lastPathComponent), ["5.jpg"])
    }
}
