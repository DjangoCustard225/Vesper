import XCTest
@testable import VesperCore

private actor SearchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false

    func pause() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor final class SearchLoadingTests: XCTestCase {
    private func item(_ id: String) -> MediaItem { MediaItem(id: id, type: "movie", name: id) }

    func testProviderResultsKeepTMDBFirstAndDeduplicateAcrossProviders() async {
        let controller = SearchController()
        let source = SearchProviders(
            tmdb: { [self] _, _ in
                try? await Task.sleep(for: .milliseconds(20))
                return TMDBPage(items: [item("a"), item("b")], page: 1, totalPages: 1)
            },
            addons: [
                SearchAddonProvider(name: "Addon") { _ in
                    [
                        MediaItem(id: "b", type: "movie", name: "b"),
                        MediaItem(id: "c", type: "movie", name: "c"),
                    ]
                }
            ])
        await controller.search("test", using: source, debounce: .zero)
        XCTAssertEqual(controller.items.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(controller.loading)
        XCTAssertFalse(controller.searchingProviders)
    }

    func testPaginationAppendsOnlyNewTMDBTitles() async {
        let controller = SearchController()
        let source = SearchProviders(tmdb: { [self] _, page in
            TMDBPage(items: page == 1 ? [item("a")] : [item("a"), item("b")], page: page, totalPages: 2)
        })
        await controller.search("test", using: source, debounce: .zero)
        XCTAssertTrue(controller.hasMore)
        await controller.loadMore()
        XCTAssertEqual(controller.items.map(\.id), ["a", "b"])
        XCTAssertFalse(controller.hasMore)
    }

    func testLateResultFromReplacedQueryIsIgnored() async {
        let controller = SearchController(), gate = SearchGate()
        let slow = SearchProviders(addons: [
            SearchAddonProvider(name: "Slow") { _ in
                await gate.pause()
                return [MediaItem(id: "old", type: "movie", name: "old")]
            }
        ])
        let first = Task { await controller.search("old", using: slow, debounce: .zero) }
        for _ in 0..<500 {
            if await gate.waiting { break }
            await Task.yield()
        }
        let started = await gate.waiting
        XCTAssertTrue(started)
        let fast = SearchProviders(addons: [
            SearchAddonProvider(name: "Fast") { _ in
                [MediaItem(id: "new", type: "movie", name: "new")]
            }
        ])
        await controller.search("new", using: fast, debounce: .zero)
        await gate.release()
        await first.value
        XCTAssertEqual(controller.items.map(\.id), ["new"])
    }

    func testReplacingQueryCancelsTheOldProvider() async {
        let controller = SearchController()
        let started = expectation(description: "Old provider started")
        let cancelled = expectation(description: "Old provider cancelled")
        let slow = SearchProviders(addons: [
            SearchAddonProvider(name: "Slow") { _ in
                started.fulfill()
                do { try await Task.sleep(for: .seconds(30)) } catch is CancellationError {
                    cancelled.fulfill()
                    throw CancellationError()
                }
                return []
            }
        ])
        let first = Task { await controller.search("old", using: slow, debounce: .zero) }
        await fulfillment(of: [started], timeout: 2)
        await controller.search(
            "new",
            using: SearchProviders(addons: [
                SearchAddonProvider(name: "Fast") { _ in
                    [MediaItem(id: "new", type: "movie", name: "new")]
                }
            ]), debounce: .zero)
        await fulfillment(of: [cancelled], timeout: 2)
        await first.value
        XCTAssertEqual(controller.items.map(\.id), ["new"])
    }

    func testClosingSearchCancelsPagination() async {
        let controller = SearchController()
        let started = expectation(description: "Next page started")
        let cancelled = expectation(description: "Next page cancelled")
        let source = SearchProviders(tmdb: { [self] _, page in
            if page == 1 { return TMDBPage(items: [item("first")], page: 1, totalPages: 2) }
            started.fulfill()
            do { try await Task.sleep(for: .seconds(30)) } catch is CancellationError {
                cancelled.fulfill()
                throw CancellationError()
            }
            return TMDBPage(items: [item("late")], page: 2, totalPages: 2)
        })
        await controller.search("term", using: source, debounce: .zero)
        let page = Task { await controller.loadMore() }
        await fulfillment(of: [started], timeout: 2)
        controller.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await page.value
        XCTAssertEqual(controller.items.map(\.id), ["first"])
        XCTAssertFalse(controller.loadingMore)
    }
}
