import XCTest
@testable import VesperCore

private actor SchedulingGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

final class RequestSchedulingTests: XCTestCase {
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
    func testSharedRequestHasIndependentCancellationAndNoCompletedResultCache() async throws {
        let pool = SharedRequestPool<Int>(), gate = SchedulingGate()
        let first = Task { try await pool.value(for: "same") { await gate.wait(); return 42 } }
        await waitUntil { await gate.arrivals == 1 }
        let second = Task { try await pool.value(for: "same") { XCTFail("Duplicate download"); return 0 } }
        await waitUntil { await pool.subscriberCount(for: "same") == 2 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled caller received a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        let remaining = await pool.subscriberCount(for: "same")
        XCTAssertEqual(remaining, 1)
        await gate.open()
        let result = try await second.value
        XCTAssertEqual(result, 42)
        let fresh = try await pool.value(for: "same") { 99 }
        XCTAssertEqual(fresh, 99)
    }
    func testFinalCancellationCancelsWorkAndLateCompletionCannotRemoveReplacement() async throws {
        let pool = SharedRequestPool<Int>(), oldGate = SchedulingGate(), newGate = SchedulingGate()
        let cancelled = expectation(description: "Underlying work cancelled")
        let first = Task {
            try await pool.value(for: "same") {
                await withTaskCancellationHandler { await oldGate.wait() } onCancel: { cancelled.fulfill() }
                return 1
            }
        }
        await waitUntil { await oldGate.arrivals == 1 }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [cancelled], timeout: 2)
        let second = Task { try await pool.value(for: "same") { await newGate.wait(); return 2 } }
        await waitUntil { await newGate.arrivals == 1 }
        await oldGate.open()
        let third = Task { try await pool.value(for: "same") { XCTFail("Replacement was removed"); return 3 } }
        await waitUntil { await pool.subscriberCount(for: "same") == 2 }
        await newGate.open()
        let values = try await (second.value, third.value)
        XCTAssertEqual(values.0, 2); XCTAssertEqual(values.1, 2)
    }
    func testDistinctKeysAndFailuresRemainIndependent() async throws {
        let pool = SharedRequestPool<Int>(), gate = SchedulingGate()
        let blocked = Task { try await pool.value(for: "blocked") { await gate.wait(); return 1 } }
        await waitUntil { await gate.arrivals == 1 }
        do { _ = try await pool.value(for: "other") { throw URLError(.timedOut) }; XCTFail("Expected failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let retry = try await pool.value(for: "other") { 2 }
        XCTAssertEqual(retry, 2)
        await gate.open(); _ = try await blocked.value
    }
    func testPrefetchLeavesCapacityForVisibleRequests() async throws {
        let limiter = PriorityRequestLimiter(limit: 4, prefetchLimit: 2), prefetch = SchedulingGate(), visible = SchedulingGate()
        let jobs = (0..<3).map { index in
            Task { try await limiter.run(key: "p\(index)", priority: .prefetch) { await prefetch.wait() } }
        }
        await waitUntil {
            let arrivals = await prefetch.arrivals, queued = await limiter.queuedCount
            return arrivals == 2 && queued == 1
        }
        let foreground = (0..<2).map { index in
            Task { try await limiter.run(key: "v\(index)", priority: .visible) { await visible.wait() } }
        }
        await waitUntil { await visible.arrivals == 2 }
        let count = await prefetch.arrivals
        XCTAssertEqual(count, 2)
        await prefetch.open(); await visible.open()
        for job in jobs + foreground { _ = try await job.value }
    }
    func testPromotionRunsAheadOfOlderSpeculativeWork() async throws {
        let limiter = PriorityRequestLimiter(limit: 1, prefetchLimit: 1), gate = SchedulingGate(), promotedGate = SchedulingGate()
        let occupied = Task { try await limiter.run(key: "occupied") { await gate.wait() } }
        await waitUntil { await gate.arrivals == 1 }
        let older = Task { try await limiter.run(key: "older", priority: .prefetch) { 1 } }
        await waitUntil { await limiter.queuedCount == 1 }
        let promoted = Task { try await limiter.run(key: "promoted", priority: .prefetch) { await promotedGate.wait(); return 2 } }
        await waitUntil { await limiter.queuedCount == 2 }
        await limiter.promote("promoted"); await gate.open()
        await waitUntil { await promotedGate.arrivals == 1 }
        let queued = await limiter.queuedCount
        XCTAssertEqual(queued, 1)
        await promotedGate.open()
        _ = try await occupied.value
        let result = try await promoted.value; XCTAssertEqual(result, 2)
        _ = try await older.value
    }
    func testQueuedCancellationReleasesSlotForNextRequest() async throws {
        let limiter = PriorityRequestLimiter(limit: 1, prefetchLimit: 1), gate = SchedulingGate()
        let occupied = Task { try await limiter.run(key: "occupied") { await gate.wait() } }
        await waitUntil { await gate.arrivals == 1 }
        let cancelled = Task { try await limiter.run(key: "cancelled") { XCTFail("Cancelled work executed") } }
        await waitUntil { await limiter.queuedCount == 1 }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await gate.open(); _ = try await occupied.value
        let result = try await limiter.run(key: "next") { 42 }
        XCTAssertEqual(result, 42)
    }
    func testDemandPromotionBeforeEnqueueUsesVisibleCapacity() async throws {
        let limiter = PriorityRequestLimiter(limit: 1, prefetchLimit: 0), demand = ArtworkDemand(.prefetch)
        demand.promote()
        let result = try await limiter.run(key: "poster", demand: demand) { 42 }
        XCTAssertEqual(result, 42)
    }
}
