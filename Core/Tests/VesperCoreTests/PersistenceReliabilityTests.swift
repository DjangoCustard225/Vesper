import XCTest
@testable import VesperCore

final class PersistenceReliabilityTests: XCTestCase {
    private var directory: URL!
    override func setUp() { super.setUp(); directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: directory); super.tearDown() }
    private func media(_ id: String, imdb: String? = nil, tmdb: Int? = nil, type: String = "movie") -> MediaItem {
        var value = MediaItem(id: id, type: type, name: "Title"); value.imdbID = imdb; value.tmdbID = tmdb; return value
    }
    func testCacheSurvivesRestartAndMarksStaleDataWithoutLosingIt() async throws {
        let now = Date(), cache = ResponseCache(directory: directory)
        await cache.save([media("tt1")], key: "https://provider.example/secret-config?token=private", now: now.addingTimeInterval(-301))
        let restarted = ResponseCache(directory: directory)
        let value = await restarted.value([MediaItem].self, key: "https://provider.example/secret-config?token=private", ttl: 300, now: now)
        XCTAssertEqual(value?.value.first?.id, "tt1"); XCTAssertEqual(value?.isFresh, false)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].lastPathComponent.contains("private"))
        let text = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertFalse(text.contains("secret-config")); XCTAssertFalse(text.contains("token=private"))
        let expired = await restarted.value([MediaItem].self, key: "https://provider.example/secret-config?token=private", ttl: 300, now: now.addingTimeInterval(8 * 24 * 3600))
        XCTAssertNil(expired)
    }
    func testCacheCorruptionFallsBackToMissAndClearRejectsOldWriters() async throws {
        let cache = ResponseCache(directory: directory)
        let token = await cache.token()
        await cache.save([media("tt1")], key: "catalog", token: token)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("broken".utf8).write(to: file)
        let corrupt = await cache.value([MediaItem].self, key: "catalog", ttl: 300)
        XCTAssertNil(corrupt)
        await cache.clear()
        await cache.save([media("tt2")], key: "catalog", token: token)
        let staleWrite = await cache.value([MediaItem].self, key: "catalog", ttl: 300)
        XCTAssertNil(staleWrite)
    }
    func testCacheStorageIsBounded() async throws {
        let cache = ResponseCache(directory: directory, byteLimit: 2000)
        for number in 0..<12 { await cache.save(String(repeating: "x", count: 600), key: String(number)) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, 2000)
    }
    func testConcurrentRevalidationUsesOneRefreshAndClearCancelsPendingWrites() async throws {
        let cache = ResponseCache(directory: directory), calls = LockedRequestCounter()
        let finished = expectation(description: "Single refresh finished")
        let operation: @Sendable () async throws -> Void = {
            calls.increment()
            try await Task.sleep(for: .milliseconds(30))
            await cache.save("updated", key: "catalog")
            finished.fulfill()
        }
        await cache.refresh(key: "catalog", operation: operation)
        await cache.refresh(key: "catalog", operation: operation)
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(calls.value, 1)
        let began = expectation(description: "Refresh began"), cancelled = expectation(description: "Refresh cancelled")
        await cache.refresh(key: "another") {
            began.fulfill()
            defer { cancelled.fulfill() }
            try await Task.sleep(for: .seconds(5))
            await cache.save("must-not-write", key: "another")
        }
        await fulfillment(of: [began], timeout: 2)
        await cache.clear()
        await fulfillment(of: [cancelled], timeout: 2)
        let empty = await cache.value(String.self, key: "another", ttl: 300)
        XCTAssertNil(empty)
    }
    func testLegacyLibraryMigratesAndRecoveryKeepsCorruptPrimary() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.json"), repository = LibraryRepository(url: directory.appendingPathComponent("library.json"))
        let original = LibraryState(items: [media("tt1")])
        try JSONEncoder().encode(original).write(to: url)
        XCTAssertEqual(try repository.load().state.items.first?.id, "tt1")
        try repository.save(LibraryState(items: [media("tt2")]))
        try Data("corrupt-original".utf8).write(to: url)
        let loaded = try repository.load()
        XCTAssertTrue(loaded.recovered); XCTAssertEqual(loaded.state.items.first?.id, "tt1")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "corrupt-original")
        try repository.save(loaded.state)
        let preserved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("library-corrupt-") })
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), "corrupt-original")
        XCTAssertEqual(try repository.load().state.items.first?.id, "tt1")
    }
    func testFailedWriteNeverCommitsInMemoryChangesOrLosesPreviousFile() throws {
        let url = directory.appendingPathComponent("library.json")
        let repository = LibraryRepository(url: url)
        var current = LibraryState(items: [media("tt1")])
        try repository.save(current)
        let failing = LibraryRepository(url: url) { data, destination in
            if destination == url { throw CocoaError(.fileWriteOutOfSpace) }
            try LibraryRepository.atomicWrite(data, destination)
        }
        XCTAssertThrowsError(try failing.commit(LibraryState(items: [media("tt2")]), current: &current))
        XCTAssertEqual(current.items.first?.id, "tt1")
        XCTAssertEqual(try repository.load().state.items.first?.id, "tt1")
    }
    func testOversizedDamagedFileCanBeRecoveredWithoutDiscardingIt() throws {
        let repository = LibraryRepository(url: directory.appendingPathComponent("library.json"))
        try repository.save(LibraryState(items: [media("tt1")]))
        try repository.save(LibraryState(items: [media("tt2")]))
        let oversized = Data(repeating: 0, count: 8 * 1024 * 1024 + 1)
        try oversized.write(to: repository.url)
        let recovered = try repository.load()
        XCTAssertTrue(recovered.recovered); XCTAssertEqual(recovered.state.items.first?.id, "tt1")
        try repository.save(recovered.state)
        let preserved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("library-corrupt-") })
        XCTAssertEqual(try Data(contentsOf: preserved), oversized)
        XCTAssertEqual(try repository.load().state.items.first?.id, "tt1")
    }
    func testCorruptFilesAndFutureVersionAreNeverSilentlyReplaced() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = LibraryRepository(url: directory.appendingPathComponent("library.json"))
        try Data("corrupt".utf8).write(to: repository.url)
        XCTAssertThrowsError(try repository.load())
        try Data(#"{"format":"vesper.library","version":99,"future_payload":{}}"#.utf8).write(to: repository.url)
        XCTAssertThrowsError(try repository.load()) { XCTAssertEqual($0 as? LibraryError, .unsupportedVersion) }
        XCTAssertThrowsError(try repository.save(LibraryState())) { XCTAssertEqual($0 as? LibraryError, .unsupportedVersion) }
        XCTAssertTrue(try String(contentsOf: repository.url, encoding: .utf8).contains("future_payload"))
    }
    func testBackupMergesSavedTitleAliases() throws {
        let original = media("tmdb:movie:42"), alias = media("tt123", tmdb: 42)
        let current = LibraryState(items: [original])
        let imported = LibraryState(items: [alias])
        let backup = try LibraryRepository.encode(imported)
        let merged = LibraryRepository.merging(try LibraryRepository.decode(backup), into: current)
        XCTAssertEqual(merged.items.count, 1)
        XCTAssertEqual(merged.items.first?.imdbID, "tt123")
        XCTAssertFalse(String(decoding: backup, as: UTF8.self).contains("tmdbCredential"))
        XCTAssertTrue(LibraryRepository.merging(LibraryState(), into: LibraryState()).items.isEmpty)
        XCTAssertThrowsError(try LibraryRepository.decode(Data("not a backup".utf8)))
    }
    func testOlderLibrariesAndBackupsKeepTitlesWithoutRestoringPlaybackData() throws {
        let legacy = Data(#"{"items":[{"id":"tt123","type":"movie","name":"Saved title"}],"history":[{"media":{"id":"tt456","type":"movie","name":"History only"},"videoID":"tt456","position":125,"duration":7200,"updated":200}]}"#.utf8)
        let oldState = try JSONSerialization.jsonObject(with: legacy)
        let versioned = try JSONSerialization.data(withJSONObject: ["format": "vesper.library", "version": 1, "library": oldState])
        for data in [legacy, versioned] {
            let restored = try LibraryRepository.decode(data)
            XCTAssertEqual(restored.items.map(\.id), ["tt123"])
            let exported = try LibraryRepository.encode(restored)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            XCTAssertEqual(envelope["version"] as? Int, 2)
            let library = try XCTUnwrap(envelope["library"] as? [String: Any])
            XCTAssertEqual(Set(library.keys), ["items"])
            XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("tt456"))
        }
    }
    func testLibraryUpgradePreservesOriginalRecoveryCopyAndSavedTitles() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let repository = LibraryRepository(url: directory.appendingPathComponent("library.json"))
        let original = Data(#"{"items":[{"id":"tt123","type":"movie","name":"Saved title"}],"history":[{"videoID":"old-playback-data"}]}"#.utf8)
        try original.write(to: repository.url)
        let loaded = try repository.load()
        XCTAssertFalse(loaded.recovered)
        XCTAssertEqual(try Data(contentsOf: repository.url), original)
        try repository.save(loaded.state)
        XCTAssertEqual(try Data(contentsOf: repository.backupURL), original)
        XCTAssertEqual(try repository.load().state.items.map(\.id), ["tt123"])
        XCTAssertFalse(try String(contentsOf: repository.url, encoding: .utf8).contains("history"))
    }
    func testIdentityMergesTransitiveAliasesWithoutMergingMoviesWithSeries() {
        let values = [media("tmdb:movie:42"), media("tt123"), media("custom:one", imdb: "tt123", tmdb: 42), media("tt123", type: "series"), media("different")]
        let result = MediaIdentity.unique(values)
        XCTAssertEqual(result.map(\.id), ["tmdb:movie:42", "tt123", "different"])
        XCTAssertEqual(result.first?.imdbID, "tt123"); XCTAssertEqual(result.first?.tmdbID, 42)
        XCTAssertTrue(media("tmdb:42").isSameTitle(as: media("tmdb:movie:42")))
        XCTAssertFalse(media("tmdb:tv:42").isSameTitle(as: media("tmdb:movie:42")))
        XCTAssertFalse(media("tt123").isSameTitle(as: media("tt123", type: "series")))
        let pagination = CatalogPagination(existing: [media("tmdb:movie:42")], incoming: [media("tt123", tmdb: 42)], providerHasMore: true)
        XCTAssertEqual(pagination.items.count, 1); XCTAssertFalse(pagination.hasMore)
    }
    func testEpisodeIdentityUsesKnownMappingAndNeverGuessesCustomIDs() {
        let show = media("tmdb:tv:42", imdb: "tt123", type: "series")
        XCTAssertEqual(MediaIdentity.videoID("tmdb:tv:42:2:3", for: show), "tt123:2:3")
        XCTAssertEqual(MediaIdentity.videoID("custom:42:2:3", for: show), "custom:42:2:3")
        XCTAssertEqual(MediaIdentity.videoID("tmdb:tv:42:2:0", for: show), "tmdb:tv:42:2:0")
    }
}
