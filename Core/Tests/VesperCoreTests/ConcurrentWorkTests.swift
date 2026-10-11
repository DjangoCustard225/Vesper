import XCTest
@testable import VesperCore

private actor WorkProbe {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var started = 0
    func begin() { active += 1; started += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}

final class ConcurrentWorkTests: XCTestCase {
    func testBoundedSchedulingDeliversEveryResultWithOriginalIndex() async {
        let probe = WorkProbe()
        var results: [Int: Int] = [:]
        await ConcurrentWork.run(Array(0..<20), limit: 3, operation: { value in
            await probe.begin(); try? await Task.sleep(for: .milliseconds(5)); await probe.end()
            return value * value
        }) { index, value in results[index] = value }
        let peak = await probe.peak, active = await probe.active
        XCTAssertEqual(peak, 3); XCTAssertEqual(active, 0)
        XCTAssertEqual(results, Dictionary(uniqueKeysWithValues: (0..<20).map { ($0, $0 * $0) }))
    }
    func testOverlappingRequestBatchesShareOneLimit() async throws {
        let limiter = RequestLimiter(limit: 2), probe = WorkProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await limiter.run {
                        await probe.begin(); try await Task.sleep(for: .milliseconds(3)); await probe.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await probe.peak, active = await probe.active, count = await probe.started
        XCTAssertEqual(peak, 2); XCTAssertEqual(active, 0); XCTAssertEqual(count, 20)
    }
    func testCancellationReleasesOccupiedAndQueuedPermits() async throws {
        let limiter = RequestLimiter(limit: 1), probe = WorkProbe()
        let first = Task {
            try await limiter.run {
                await probe.begin()
                try await Task.sleep(for: .seconds(60))
            }
        }
        for _ in 0..<500 {
            if await probe.started == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let queued = Task { try await limiter.run { XCTFail("Cancelled waiter ran"); return 1 } }
        await Task.yield(); queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        first.cancel()
        do { try await first.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let result = try await limiter.run { 42 }
        XCTAssertEqual(result, 42)
    }
    func testDiagnosticsStillDecodeRemovedSubtitleCategory() throws {
        let event = try JSONDecoder().decode(DiagnosticEvent.self, from: Data(#"{"date":0,"operation":"subtitles","attempt":1,"milliseconds":1,"status":200,"outcome":"success"}"#.utf8))
        XCTAssertEqual(event.operation, .metadata)
    }
}
