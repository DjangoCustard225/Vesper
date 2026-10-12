import XCTest
@testable import VesperCore

private actor PrefetchProbe {
    private struct Pending { let url: URL; let continuation: CheckedContinuation<Void, Never> }
    private var pending: [UUID: Pending] = [:]
    private(set) var starts: [URL: Int] = [:]
    private(set) var cancellations: [URL: Int] = [:]
    func load(_ url: URL) async {
        let id = UUID()
        starts[url, default: 0] += 1
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { pending[id] = Pending(url: url, continuation: $0) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func finish(_ url: URL) {
        for (id, work) in pending where work.url == url {
            pending[id] = nil
            work.continuation.resume()
        }
    }
    private func cancel(_ id: UUID) {
        guard let work = pending.removeValue(forKey: id) else { return }
        cancellations[work.url, default: 0] += 1
        work.continuation.resume()
    }
}

@MainActor final class ArtworkPrefetchControllerTests: XCTestCase {
    private let a = URL(string: "https://images.example/original/a.jpg")!
    private let b = URL(string: "https://images.example/original/b.jpg")!
    private let c = URL(string: "https://images.example/original/c.jpg")!
    private let d = URL(string: "https://images.example/original/d.jpg")!
    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Prefetch condition was not reached", file: file, line: line)
    }
    func testMovingWindowRetainsOverlapAndRespectsTheConcurrencyLimit() async {
        let probe = PrefetchProbe()
        let controller = ArtworkPrefetchController { await probe.load($0) }
        controller.update([a, b, c])
        await waitUntil { await probe.starts.count == 2 }
        controller.update([b, c, d])
        await waitUntil { await probe.starts[c] == 1 }
        let before = await probe.starts
        XCTAssertEqual(before, [a: 1, b: 1, c: 1])
        await waitUntil { await probe.cancellations[a] == 1 }
        let cancellations = await probe.cancellations
        XCTAssertNil(cancellations[b])
        await probe.finish(b)
        await waitUntil { await probe.starts[d] == 1 }
        let after = await probe.starts
        XCTAssertEqual(after, [a: 1, b: 1, c: 1, d: 1])
        controller.cancel()
    }
    func testDuplicateURLsAndReorderingDoNotRestartRequests() async {
        let probe = PrefetchProbe()
        let controller = ArtworkPrefetchController { await probe.load($0) }
        controller.update([a, a, b])
        await waitUntil { await probe.starts.count == 2 }
        controller.update([b, a, b])
        await probe.finish(a); await probe.finish(b)
        controller.update([a, b])
        // Let completion callbacks and any erroneous duplicate work execute.
        for _ in 0..<20 { await Task.yield() }
        let starts = await probe.starts
        XCTAssertEqual(starts, [a: 1, b: 1])
        controller.cancel()
    }
    func testCancelledScreenCanPrefetchAgainAndDropsQueuedWork() async {
        let probe = PrefetchProbe()
        let controller = ArtworkPrefetchController { await probe.load($0) }
        controller.update([a, b, c])
        await waitUntil { await probe.starts.count == 2 }
        controller.cancel()
        await waitUntil { await probe.cancellations.count == 2 }
        let cancelled = await probe.starts
        XCTAssertNil(cancelled[c])
        controller.update([a])
        await waitUntil { await probe.starts[a] == 2 }
        controller.cancel()
    }
    func testCompletedArtworkIsNotRepeatedWhileItRemainsInTheWindow() async {
        let probe = PrefetchProbe()
        let controller = ArtworkPrefetchController(limit: 1) { await probe.load($0) }
        controller.update([a, b])
        await waitUntil { await probe.starts[a] == 1 }
        await probe.finish(a)
        await waitUntil { await probe.starts[b] == 1 }
        controller.update([a, b, c])
        await probe.finish(b)
        await waitUntil { await probe.starts[c] == 1 }
        let starts = await probe.starts
        XCTAssertEqual(starts, [a: 1, b: 1, c: 1])
        controller.cancel()
    }
    func testEmptyWindowCancelsActiveRequestsWithoutStartingQueuedArtwork() async {
        let probe = PrefetchProbe()
        let controller = ArtworkPrefetchController(limit: 1) { await probe.load($0) }
        controller.update([a, b])
        await waitUntil { await probe.starts[a] == 1 }
        controller.update([])
        await waitUntil { await probe.cancellations[a] == 1 }
        let starts = await probe.starts
        XCTAssertEqual(starts, [a: 1])
    }
}
