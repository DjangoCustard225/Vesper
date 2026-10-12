import XCTest
@testable import VesperCore

final class ExpiringCacheTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1000)

    func testReadsDoNotExtendFreshness() {
        var cache = ExpiringCache<Int>(lifetime: 10, capacity: 2)
        cache.insert(1, for: "title", now: start)
        XCTAssertEqual(cache.value(for: "title", now: start.addingTimeInterval(9)), 1)
        XCTAssertNil(cache.value(for: "title", now: start.addingTimeInterval(10)))
    }

    func testReplacingEntryAtCapacityKeepsOtherEntries() {
        var cache = ExpiringCache<Int>(lifetime: 10, capacity: 2)
        cache.insert(1, for: "first", now: start)
        cache.insert(2, for: "second", now: start.addingTimeInterval(1))
        cache.insert(3, for: "second", now: start.addingTimeInterval(2))
        XCTAssertEqual(cache.value(for: "first", now: start.addingTimeInterval(2)), 1)
        XCTAssertEqual(cache.value(for: "second", now: start.addingTimeInterval(2)), 3)
    }

    func testInsertionEvictsOldestWithoutExtendingRecentlyReadEntries() {
        var cache = ExpiringCache<Int>(lifetime: 10, capacity: 2)
        cache.insert(1, for: "first", now: start)
        cache.insert(2, for: "second", now: start.addingTimeInterval(1))
        _ = cache.value(for: "first", now: start.addingTimeInterval(2))
        cache.insert(3, for: "third", now: start.addingTimeInterval(3))
        XCTAssertNil(cache.value(for: "first", now: start.addingTimeInterval(3)))
        XCTAssertEqual(cache.value(for: "second", now: start.addingTimeInterval(3)), 2)
        XCTAssertEqual(cache.value(for: "third", now: start.addingTimeInterval(3)), 3)
    }

    func testExpiredEntriesDoNotEvictFreshEntries() {
        var cache = ExpiringCache<Int>(lifetime: 10, capacity: 2)
        cache.insert(1, for: "expired", now: start)
        cache.insert(2, for: "fresh", now: start.addingTimeInterval(5))
        cache.insert(3, for: "new", now: start.addingTimeInterval(10))
        XCTAssertNil(cache.value(for: "expired", now: start.addingTimeInterval(10)))
        XCTAssertEqual(cache.value(for: "fresh", now: start.addingTimeInterval(10)), 2)
        XCTAssertEqual(cache.value(for: "new", now: start.addingTimeInterval(10)), 3)
    }

    func testResetCannotReturnPreviousCredentialsEntries() {
        var cache = ExpiringCache<Int>(lifetime: 10, capacity: 2)
        cache.insert(1, for: "title", now: start)
        cache.removeAll()
        XCTAssertNil(cache.value(for: "title", now: start))
        cache.insert(2, for: "title", now: start)
        XCTAssertEqual(cache.value(for: "title", now: start), 2)
    }
}
