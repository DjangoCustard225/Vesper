import Foundation
import XCTest
@testable import UsenetEngine

final class StreamingTests: XCTestCase {
    func testOfficialRARFixturesStreamExactlyAcrossVolumes() async throws {
        // Independent fixtures made by the RAR utility, rather than by the synthetic header encoder.
        for prefix in ["legacy", "small"] {
            let source = FixtureSource(), directory = temporaryDirectory()
            var files: [NZBFile] = []
            for index in 1...3 {
                let url = try XCTUnwrap(
                    Bundle.module.url(
                        forResource: "\(prefix).part\(index)", withExtension: "rar", subdirectory: "Fixtures")
                )
                let data = try Data(contentsOf: url)
                files.append(await source.add(data, id: index - 1, name: url.lastPathComponent, chunk: 511))
            }
            let session = try UsenetSession(
                manifest: NZBManifest(files: files), source: source, cacheDirectory: directory)
            let catalog = try await session.catalog(), video = try XCTUnwrap(catalog.first)
            XCTAssertEqual(catalog.count, 1)
            let actual = try await session.read(video: video, offset: 0, count: 8192)
            XCTAssertEqual(actual, Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) }))
            await session.stop()
        }
    }
    func testRawStreamingReadsActualBytesAcrossArticlesAndSeeks() async throws {
        let source = FixtureSource(), directory = temporaryDirectory()
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        let file = await source.add(payload, id: 0, name: "movie.mp4", chunk: 1777)
        let session = try UsenetSession(
            manifest: NZBManifest(files: [file]), source: source, cacheDirectory: directory)
        let catalog = try await session.catalog(), video = try XCTUnwrap(catalog.first)
        XCTAssertEqual(video.length, Int64(payload.count))
        for (offset, count) in [(0, 100), (1700, 3000), (9900, 1000), (3000, 300), (0, 10)] {
            let bytes = try await session.read(video: video, offset: Int64(offset), count: count)
            XCTAssertEqual(bytes, payload.subdata(in: offset..<min(payload.count, offset + count)))
        }
        await session.stop(); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testConcurrentRequestsDeduplicateAndOneCancelledReaderDoesNotPoisonOthers() async throws {
        let source = FixtureSource(delay: .milliseconds(30)), directory = temporaryDirectory()
        let file = await source.add(Data(repeating: 42, count: 100), id: 0, name: "movie.mp4")
        let cache = try ArticleCache(source: source, directory: directory)
        let one = Task { try await cache.data(file: file, index: 0, priority: .playback).1 }
        let two = Task { try await cache.data(file: file, index: 0, priority: .playback).1 }
        try await Task.sleep(for: .milliseconds(5)); one.cancel()
        do { _ = try await one.value; XCTFail("Cancelled reader succeeded") } catch is CancellationError {
        } catch { XCTFail("Wrong cancellation: \(error)") }
        let bytes = try await two.value, calls = await source.count("0-0@fixture")
        XCTAssertEqual(bytes, Data(repeating: 42, count: 100)); XCTAssertEqual(calls, 1)
        await cache.stop()
    }
    func testTransientConnectionRetriesOnceButMissingArticlesAreNeverCachedAsZeroes() async throws {
        let source = FixtureSource(), directory = temporaryDirectory()
        let file = await source.add(Data(repeating: 7, count: 200), id: 0, name: "movie.mp4", chunk: 100)
        await source.fail("0-0@fixture", errors: [.connection])
        let cache = try ArticleCache(source: source, directory: directory)
        let first = try await cache.data(file: file, index: 0, priority: .playback).1
        XCTAssertEqual(first, Data(repeating: 7, count: 100))
        let calls = await source.count("0-0@fixture"); XCTAssertEqual(calls, 2)
        await source.replace("0-1@fixture", lines: nil)
        await expectError(.missingArticle) {
            _ = try await cache.data(file: file, index: 1, priority: .playback)
        }
        let stored = await cache.storedBytes; XCTAssertEqual(stored, 100)
        await cache.stop()
    }
    func testInconsistentAndGappedOffsetsFailBeforeReturningData() async throws {
        let source = FixtureSource(), directory = temporaryDirectory()
        let file = await source.add(Data(repeating: 7, count: 300), id: 0, name: "movie.mp4", chunk: 100)
        await source.replace(
            "0-1@fixture",
            lines: encoded(Data(repeating: 7, count: 90), offset: 110, size: 300, part: 2, total: 3))
        let cache = try ArticleCache(source: source, directory: directory),
            reader = NZBFileReader(file: file, cache: cache)
        await expectError(.missingArticle) { _ = try await reader.read(offset: 90, count: 30) }
        await cache.stop()
    }
    func testCacheEvictsAndCanRedownloadAnEarlierArticle() async throws {
        let source = FixtureSource(), directory = temporaryDirectory()
        let file = await source.add(
            Data(repeating: 1, count: 9 * 1024 * 1024), id: 0, name: "movie.mp4", chunk: 3 * 1024 * 1024)
        let cache = try ArticleCache(source: source, directory: directory, limit: 8 * 1024 * 1024)
        for index in 0..<3 { _ = try await cache.data(file: file, index: index, priority: .playback) }
        let bytes = await cache.storedBytes; XCTAssertLessThanOrEqual(bytes, 8 * 1024 * 1024)
        _ = try await cache.data(file: file, index: 0, priority: .playback)
        let calls = await source.count("0-0@fixture"); XCTAssertEqual(calls, 2)
        await cache.stop()
    }
    func testRAR4AndRAR5StoredVolumesStreamAcrossBoundaries() async throws {
        for version in [4, 5] {
            let source = FixtureSource(), directory = temporaryDirectory()
            let first = Data((0..<301).map { UInt8(truncatingIfNeeded: $0) }),
                second = Data((301..<777).map { UInt8(truncatingIfNeeded: $0) })
            let archive1 =
                version == 4 ? rar4(first, total: 777, after: true) : rar5(first, total: 777, after: true)
            let archive2 =
                version == 4 ? rar4(second, total: 777, before: true) : rar5(second, total: 777, before: true)
            let file1 = await source.add(archive1, id: 0, name: "release.part01.rar", chunk: 101)
            let file2 = await source.add(archive2, id: 1, name: "release.part02.rar", chunk: 101)
            let session = try UsenetSession(
                manifest: NZBManifest(files: [file1, file2]), source: source, cacheDirectory: directory)
            let videos = try await session.catalog(), video = try XCTUnwrap(videos.first)
            XCTAssertEqual(video.length, 777); XCTAssertEqual(video.extents.count, 2)
            let read = try await session.read(video: video, offset: 250, count: 400)
            XCTAssertEqual(read, (first + second).subdata(in: 250..<650), "RAR \(version)")
            await session.stop()
        }
    }
    func testArchivesRejectCompressedEncryptedCorruptAndMissingVolumes() async throws {
        let payload = Data(repeating: 1, count: 100)
        for version in [4, 5] {
            let compressed = version == 4 ? rar4(payload, compressed: true) : rar5(payload, compressed: true)
            let encrypted = version == 4 ? rar4(payload, encrypted: true) : rar5(payload, encrypted: true)
            for (data, error) in [(compressed, UsenetError.compressed), (encrypted, .encrypted)] {
                let volume = try await StoredRAR.scan(MemoryResource(data: data))
                XCTAssertThrowsError(try StoredRAR.videos([(0, volume)], startingAt: 0)) {
                    XCTAssertEqual($0 as? UsenetError, error)
                }
            }
            let split =
                version == 4 ? rar4(payload, total: 200, after: true) : rar5(payload, total: 200, after: true)
            let volume = try await StoredRAR.scan(MemoryResource(data: split))
            XCTAssertThrowsError(try StoredRAR.videos([(0, volume)], startingAt: 0)) {
                XCTAssertEqual($0 as? UsenetError, .missingArticle)
            }
            var corrupt = version == 4 ? rar4(payload) : rar5(payload); corrupt[10] ^= 1
            await expectError(.corrupt) { _ = try await StoredRAR.scan(MemoryResource(data: corrupt)) }
        }
    }
    func testStopReleasesSilentInFlightFetchAndDoesNotLeaveCacheFiles() async throws {
        let source = FixtureSource(delay: .seconds(10)), directory = temporaryDirectory()
        let file = await source.add(Data([1, 2, 3]), id: 0, name: "movie.mp4")
        let cache = try ArticleCache(source: source, directory: directory)
        let task = Task { try await cache.data(file: file, index: 0, priority: .playback) }
        try await Task.sleep(for: .milliseconds(10)); await cache.stop()
        do { _ = try await task.value; XCTFail("Stopped cache returned bytes") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
