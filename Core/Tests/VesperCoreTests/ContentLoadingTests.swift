import XCTest
@testable import VesperCore

private actor LoadingGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() { opened = true; waiting.forEach { $0.resume() }; waiting = [] }
}

@MainActor
private final class LoadingFixture {
    var updated = false
    var fail = false
    var calls: [Int] = []
}

@MainActor
final class ContentLoadingTests: XCTestCase {
    private func item(_ id: String) -> MediaItem { MediaItem(id: id, type: "movie", name: id) }
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
    func testCatalogRefreshReplacesTheAffectedPageWithoutLosingLaterPages() async {
        let model = CatalogController()
        let fixture = LoadingFixture()
        let source = ContentSource { cursor in
            fixture.calls.append(cursor)
            let ids = cursor == 1 ? (fixture.updated ? ["tt3", "tt5"] : ["tt1", "tt2"]) : ["tt3", "tt4"]
            return ContentPage(items: ids.map(self.item), nextCursor: cursor == 1 ? 2 : nil, cacheID: "cache\(cursor)")
        }
        await model.load(source); await model.loadMore()
        model.refresh(cacheIDs: ["unrelated"]); await Task.yield(); XCTAssertEqual(fixture.calls, [1, 2])
        fixture.updated = true; model.refresh(cacheIDs: ["cache1"])
        await waitUntil { model.items.map(\.id) == ["tt3", "tt5", "tt4"] }
        XCTAssertEqual(fixture.calls, [1, 2, 1]); XCTAssertFalse(model.hasMore)
    }
    func testCatalogFailedNextPageKeepsItemsAndRetriesSameCursor() async {
        let model = CatalogController()
        let fixture = LoadingFixture(); fixture.fail = true
        let source = ContentSource { cursor in
            fixture.calls.append(cursor)
            if cursor == 2 && fixture.fail { throw URLError(.notConnectedToInternet) }
            return ContentPage(items: [self.item("tt\(cursor)")], nextCursor: cursor == 1 ? 2 : nil)
        }
        await model.load(source); await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["tt1"]); XCTAssertNotNil(model.error); XCTAssertTrue(model.hasMore)
        fixture.fail = false; await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["tt1", "tt2"]); XCTAssertEqual(fixture.calls, [1, 2, 2]); XCTAssertNil(model.error)
    }
    func testNewCatalogRejectsOldFilterResponse() async {
        let gate = LoadingGate(), model = CatalogController()
        let pending = Task { await model.load(ContentSource { _ in await gate.wait(); return ContentPage(items: [self.item("old")]) }) }
        await waitUntil { await gate.arrivals == 1 }
        await model.load(ContentSource { _ in ContentPage(items: [self.item("new")]) })
        await gate.open(); await pending.value
        XCTAssertEqual(model.items.map(\.id), ["new"]); XCTAssertFalse(model.loading)
    }
    func testRepeatedCatalogPageStopsAutomaticPagination() async {
        let model = CatalogController()
        await model.load(ContentSource { cursor in
            ContentPage(items: [self.item("tt1")], nextCursor: cursor + 1)
        })
        await model.loadMore()
        XCTAssertEqual(model.items.count, 1); XCTAssertFalse(model.hasMore)
    }
    func testCacheUpdateDuringInitialCatalogFetchIsAppliedAfterThePageArrives() async {
        let gate = LoadingGate(), model = CatalogController()
        var calls = 0
        let source = ContentSource { _ in
            calls += 1
            let first = calls == 1
            if first { await gate.wait() }
            return ContentPage(items: [self.item(first ? "stale" : "fresh")], cacheID: "catalog-cache")
        }
        let initial = Task { await model.load(source) }
        await waitUntil { await gate.arrivals == 1 }
        model.refresh(cacheIDs: ["unrelated", "catalog-cache"])
        await gate.open(); await initial.value
        await waitUntil { model.items.first?.id == "fresh" }
        XCTAssertEqual(calls, 2)
    }
    func testFailedTargetedRevalidationPreservesVisibleCatalog() async {
        let model = CatalogController()
        let fixture = LoadingFixture()
        await model.load(ContentSource { _ in
            fixture.calls.append(1)
            if fixture.fail { throw URLError(.notConnectedToInternet) }
            return ContentPage(items: [self.item("tt1")], cacheID: "catalog-cache")
        })
        fixture.fail = true; model.refresh(cacheIDs: ["catalog-cache"])
        await waitUntil { fixture.calls.count == 2 }
        XCTAssertEqual(model.items.map(\.id), ["tt1"]); XCTAssertNil(model.error)
    }
}
