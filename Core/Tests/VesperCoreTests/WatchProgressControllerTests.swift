import XCTest
@testable import VesperCore

@MainActor
final class WatchProgressControllerTests: XCTestCase {
    private let movie = MediaItem(id: "tt1", type: "movie", name: "Movie")

    private func withRepository(_ body: (WatchProgressRepository) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(WatchProgressRepository(url: directory.appendingPathComponent("progress.json")))
    }

    func testQueuedMutationsUseLatestCommittedState() async throws {
        try await withRepository { repository in
            let controller = WatchProgressController(repository: repository)
            let second = MediaItem(id: "tt2", type: "movie", name: "Second")
            controller.setWatched(true, for: movie)
            controller.setWatched(true, for: second)
            await controller.flush()
            XCTAssertTrue(controller.state.isWatched(movie))
            XCTAssertTrue(controller.isWatched(movie))
            XCTAssertTrue(controller.state.isWatched(second))
            XCTAssertEqual(try repository.load().state.records.count, 2)
            controller.setWatched(false, for: movie)
            await controller.flush()
            XCTAssertFalse(controller.state.isWatched(movie))
            XCTAssertFalse(controller.isWatched(movie))
            XCTAssertTrue(controller.state.isWatched(second))
        }
    }

    func testFailedWriteDoesNotPublishProposedState() async throws {
        try await withRepository { repository in
            let failing = WatchProgressRepository(url: repository.url) { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let controller = WatchProgressController(repository: failing)
            controller.setWatched(true, for: movie)
            await controller.flush()
            XCTAssertFalse(controller.state.isWatched(movie))
            XCTAssertFalse(controller.isWatched(movie))
            XCTAssertNotNil(controller.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url.path))
        }
    }

    func testFailedMutationDoesNotPoisonLaterQueuedSave() async throws {
        try await withRepository { repository in
            let writes = LockedRequestCounter()
            let recovering = WatchProgressRepository(url: repository.url) { data, url in
                writes.increment()
                if writes.value == 1 { throw CocoaError(.fileWriteOutOfSpace) }
                try PersistenceIO.write(data, url)
            }
            let controller = WatchProgressController(repository: recovering)
            let second = MediaItem(id: "tt2", type: "movie", name: "Second")
            controller.setWatched(true, for: movie)
            controller.setWatched(true, for: second)
            await controller.flush()
            XCTAssertFalse(controller.state.isWatched(movie))
            XCTAssertTrue(controller.state.isWatched(second))
            XCTAssertTrue(try repository.load().state.isWatched(second))
        }
    }

    func testUnreadableProgressRemainsReadOnlyAfterDismissingError() async throws {
        try await withRepository { repository in
            try FileManager.default.createDirectory(
                at: repository.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let damaged = Data("damaged".utf8)
            try damaged.write(to: repository.url)
            let controller = WatchProgressController(repository: repository)
            XCTAssertNotNil(controller.error)
            controller.error = nil
            controller.setWatched(true, for: movie)
            await controller.flush()
            XCTAssertNotNil(controller.error)
            XCTAssertTrue(controller.state.records.isEmpty)
            XCTAssertEqual(try Data(contentsOf: repository.url), damaged)
        }
    }

    func testRecoveryLoadsPreviousStateAndReportsRecovery() async throws {
        try await withRepository { repository in
            var progress = WatchProgress()
            progress.setWatched(true, for: movie)
            try repository.save(progress)
            try repository.save(progress)
            try Data("damaged".utf8).write(to: repository.url)
            let controller = WatchProgressController(repository: repository)
            XCTAssertTrue(controller.state.isWatched(movie))
            XCTAssertTrue(controller.isWatched(movie))
            XCTAssertNotNil(controller.error)
        }
    }

    func testPlaybackAndManualMarkAreSerializedInInvocationOrder() async throws {
        try await withRepository { repository in
            let controller = WatchProgressController(repository: repository)
            controller.record(
                media: movie, videoID: movie.id, subtitle: nil,
                update: PlaybackProgressUpdate(elapsed: 100, duration: 1000, ended: false))
            controller.setWatched(true, for: movie)
            await controller.flush()
            XCTAssertTrue(controller.state.isWatched(movie))
            XCTAssertEqual(controller.state.records.count, 1)
            XCTAssertNil(controller.state.records.first?.videoID)
            XCTAssertTrue(try repository.load().state.isWatched(movie))
        }
    }
}
