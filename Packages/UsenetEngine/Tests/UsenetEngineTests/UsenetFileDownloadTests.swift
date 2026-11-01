import Foundation
import XCTest
@testable import UsenetEngine

final class UsenetFileDownloadTests: XCTestCase {
    func testDownloadWritesExactVideoAndReportsProgress() async throws {
        let source = FixtureSource(), directory = temporaryDirectory()
        let payload = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0) })
        let file = await source.add(payload, id: 0, name: "movie.mp4", chunk: 250_000)
        let session = try UsenetSession(
            manifest: NZBManifest(files: [file]), source: source, cacheDirectory: directory)
        let videos = try await session.catalog()
        let destination = temporaryDirectory().appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        let values = ProgressCapture()
        try await UsenetFileDownload.write(
            video: try XCTUnwrap(videos.first), session: session, to: destination
        ) { done, total in
            await values.add(done, total)
        }
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        let progress = await values.items
        XCTAssertEqual(progress.last?.0, Int64(payload.count))
        XCTAssertEqual(progress.last?.1, Int64(payload.count))
        await session.stop()
    }
    func testConnectionSettingControlsParallelReadsAndPreservesOrder() async throws {
        let payload = Data((0..<(8 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        for limit in [1, 4] {
            let source = FixtureSource(delay: .milliseconds(30)), directory = temporaryDirectory()
            let file = await source.add(payload, id: 0, name: "movie.mp4", chunk: 512 * 1024)
            let session = try UsenetSession(
                manifest: NZBManifest(files: [file]), source: source, cacheDirectory: directory)
            let videos = try await session.catalog(), video = try XCTUnwrap(videos.first)
            await source.resetPeak()
            let destination = temporaryDirectory().appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: destination) }
            try await UsenetFileDownload.write(
                video: video, session: session, to: destination, connections: limit)
            let peak = await source.peakInFlight
            XCTAssertLessThanOrEqual(peak, limit)
            if limit == 4 { XCTAssertGreaterThanOrEqual(peak, 3) }
            XCTAssertEqual(try Data(contentsOf: destination), payload)
            await session.stop()
        }
    }
    func testCancelledDownloadRemovesIncompleteOutput() async throws {
        let source = FixtureSource(delay: .milliseconds(40)), directory = temporaryDirectory()
        let file = await source.add(
            Data(repeating: 1, count: 300_000), id: 0, name: "movie.mp4", chunk: 100_000)
        let session = try UsenetSession(
            manifest: NZBManifest(files: [file]), source: source, cacheDirectory: directory)
        let videos = try await session.catalog(), video = try XCTUnwrap(videos.first)
        let destination = temporaryDirectory().appendingPathExtension("mp4")
        let task = Task {
            try await UsenetFileDownload.write(video: video, session: session, to: destination)
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation should fail") } catch is CancellationError {} catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await session.stop()
    }
}
private actor ProgressCapture {
    var items: [(Int64, Int64)] = []
    func add(_ done: Int64, _ total: Int64) { items.append((done, total)) }
}
