import XCTest
@testable import VesperCore

private final class ProgressWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var writes = 0
    private var maximumActive = 0

    var snapshot: (writes: Int, maximumActive: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (writes, maximumActive)
    }

    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        active += 1
        writes += 1
        maximumActive = max(maximumActive, active)
        lock.unlock()
        defer {
            lock.lock()
            active -= 1
            lock.unlock()
        }
        Thread.sleep(forTimeInterval: 0.02)
        try data.write(to: url, options: .atomic)
    }
}

final class WatchProgressWriterTests: XCTestCase {
    private func state(_ elapsed: Double) -> WatchProgress {
        var state = WatchProgress()
        state.record(
            media: MediaItem(id: "tt1", type: "movie", name: "Movie"),
            videoID: "tt1", subtitle: nil, elapsed: elapsed, duration: 1000)
        return state
    }

    func testOverlappingSavesRemainOrderedAndRecoverable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.json"), probe = ProgressWriteProbe()
        let repository = WatchProgressRepository(url: url) { try probe.write($0, to: $1) }
        let writer = WatchProgressWriter(repository: repository)
        let firstState = state(100), secondState = state(200)
        let first = Task { try await writer.save(firstState) }
        for _ in 0..<500 {
            if probe.snapshot.writes > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertGreaterThan(probe.snapshot.writes, 0)
        let second = Task { try await writer.save(secondState) }
        try await first.value
        try await second.value
        XCTAssertEqual(probe.snapshot.maximumActive, 1)
        XCTAssertEqual(try repository.load().state.records.first?.elapsed, 200)
        XCTAssertEqual(
            try WatchProgressRepository.decode(Data(contentsOf: repository.backupURL)).records.first?.elapsed,
            100)
    }

    func testFailedSaveKeepsPreviousCheckpointAndAllowsLaterSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("progress.json")
        let repository = WatchProgressRepository(url: url)
        try repository.save(state(100))
        let failing = WatchProgressRepository(url: url) { data, destination in
            if destination == url { throw CocoaError(.fileWriteOutOfSpace) }
            try PersistenceIO.write(data, destination)
        }
        let writer = WatchProgressWriter(repository: failing)
        do {
            try await writer.save(state(200))
            XCTFail("Expected a write failure")
        } catch {
            XCTAssertTrue(error is WatchProgressError)
        }
        XCTAssertEqual(try repository.load().state.records.first?.elapsed, 100)
        try await WatchProgressWriter(repository: repository).save(state(300))
        XCTAssertEqual(try repository.load().state.records.first?.elapsed, 300)
    }
}
