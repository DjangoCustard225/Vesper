import XCTest
@testable import VesperCore

final class DownloadIntegrationTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func record(media: MediaItem? = nil, episode: Int? = nil) throws -> DownloadRecord {
        let item = media ?? MediaItem(id: "tt1", type: episode == nil ? "movie" : "series", name: "A / Show")
        let ep = try episode.map { number in
            try JSONDecoder().decode(
                Episode.self,
                from: Data("{\"id\":\"tt1:1:\(number)\",\"season\":1,\"episode\":\(number)}".utf8))
        }
        let source = try JSONDecoder().decode(
            StreamSource.self, from: Data(#"{"url":"https://files.example/play","name":"1080p"}"#.utf8))
        var value = DownloadRecord(
            media: item, videoID: ep?.id ?? item.id, subtitle: nil, episode: ep, source: source,
            providerID: nil, fetchedAt: Date())
        value.phase = .completed; value.fileName = value.id.uuidString + ".mkv"; value.receivedBytes = 8;
        value.expectedBytes = 8
        return value
    }
    private func bytes() -> Data { Data([0x1a, 0x45, 0xdf, 0xa3, 0, 1, 2, 3]) }
    private func install(_ value: DownloadRecord, root: URL) throws {
        try bytes().write(to: root.appendingPathComponent("Media").appendingPathComponent(value.fileName!))
    }
    func testPlaybackUsesExactAliasesAndEpisodeIdentityWithoutTitleGuessing() throws {
        var saved = try record(episode: 2); saved.media.tmdbID = 123
        let enriched = MediaItem(id: "tmdb:tv:123", type: "series", name: "Different title")
        XCTAssertTrue(DownloadPlayback.matches(saved, media: enriched, videoID: "tmdb:tv:123:1:2"))
        XCTAssertFalse(DownloadPlayback.matches(saved, media: enriched, videoID: "tmdb:tv:123:1:3"))
        XCTAssertFalse(
            DownloadPlayback.matches(
                saved, media: MediaItem(id: "tt2", type: "series", name: saved.media.name),
                videoID: saved.videoID))
        saved.phase = .downloading
        XCTAssertFalse(DownloadPlayback.matches(saved, media: enriched, videoID: "tmdb:tv:123:1:2"))
    }
    func testMovieVersionsRemainCandidatesButMoviesNeverMatchShows() throws {
        let value = try record()
        XCTAssertTrue(DownloadPlayback.matches(value, media: value.media, videoID: "some-source-video"))
        let other = MediaItem(id: value.media.id, type: "series", name: value.media.name)
        XCTAssertFalse(DownloadPlayback.matches(value, media: other, videoID: value.videoID))
    }
    func testOfflineUpNextNeverSkipsMissingEpisodesAndIgnoresDuplicateVersions() throws {
        let first = try record(episode: 1), second = try record(episode: 2), third = try record(episode: 3)
        let known = [first, second, second, third].compactMap(\.episode)
        XCTAssertNil(
            DownloadPlayback.next(
                after: first.episode!, known: known, downloaded: [first, third], media: first.media,
                isWatched: { _ in false }))
        XCTAssertEqual(
            DownloadPlayback.next(
                after: first.episode!, known: known, downloaded: [first, second], media: first.media,
                isWatched: { _ in false })?.id, second.episode?.id)
        XCTAssertEqual(
            DownloadPlayback.next(
                after: first.episode!, known: known, downloaded: [third], media: first.media,
                isWatched: { $0.episode == 2 })?.id, third.episode?.id)
        XCTAssertNil(
            DownloadPlayback.next(
                after: first.episode!, known: [first, third].compactMap(\.episode), downloaded: [third],
                media: first.media, isWatched: { _ in false }))
    }
    func testStorageCompletesAValidatedFileAndCountsArtworkSeparatelyFromIncoming() async throws {
        let root = try temporary(), storage = DownloadStorage(root: root)
        _ = try await storage.load()
        var value = try record(); value.phase = .downloading
        var library = DownloadLibrary(); library.records = [value]
        try await storage.save(library)
        let staged = root.appendingPathComponent("Incoming/staged")
        try bytes().write(to: staged)
        try await storage.storeArtwork(Data([1, 2, 3]), name: "shared.image")
        let before = await storage.diskState()
        XCTAssertEqual(before.incomingBytes, 8); XCTAssertEqual(before.savedBytes, 3)
        let saved = try await storage.complete(
            library, key: DownloadTaskKey(id: value.id, attempt: value.attempt),
            receipt: DownloadReceipt(location: staged, status: 200, mime: "video/x-matroska", total: 8))
        XCTAssertEqual(saved.records[0].phase, .completed)
        let state = await storage.diskState()
        XCTAssertEqual(state.savedBytes, 11); XCTAssertEqual(state.incomingBytes, 0)
        let loaded = try await storage.load()
        XCTAssertEqual(loaded.records[0].phase, .completed)
    }
    func testStorageRejectsStaleAndIncompleteReceiptsWithoutPublishingCompletion() async throws {
        let root = try temporary(), storage = DownloadStorage(root: root)
        _ = try await storage.load()
        var value = try record(); value.phase = .downloading
        var library = DownloadLibrary(); library.records = [value]
        let staged = root.appendingPathComponent("Incoming/staged")
        try bytes().write(to: staged)
        let unchanged = try await storage.complete(
            library, key: DownloadTaskKey(id: value.id, attempt: UUID()),
            receipt: DownloadReceipt(location: staged, status: 200, mime: nil, total: 8))
        XCTAssertEqual(unchanged.records[0].phase, .downloading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        try bytes().write(to: staged)
        do {
            _ = try await storage.complete(
                library, key: DownloadTaskKey(id: value.id, attempt: value.attempt),
                receipt: DownloadReceipt(location: staged, status: 200, mime: nil, total: 10))
            XCTFail("Incomplete file accepted")
        } catch {}
        let file = await storage.file(value); XCTAssertNil(file)
    }
    func testFailedCompletionIndexWritePreservesFinalFileForRelaunchRecovery() async throws {
        let root = try temporary(), url = root.appendingPathComponent("index.json")
        let storage = DownloadStorage(root: root)
        _ = try await storage.load()
        var value = try record(); value.phase = .downloading
        var library = DownloadLibrary(); library.records = [value]; try await storage.save(library)
        let failing = DownloadStorage(
            root: root,
            repository: DownloadRepository(
                url: url, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        let staged = root.appendingPathComponent("Incoming/staged"); try bytes().write(to: staged)
        do {
            _ = try await failing.complete(
                library, key: DownloadTaskKey(id: value.id, attempt: value.attempt),
                receipt: DownloadReceipt(location: staged, status: 200, mime: nil, total: 8))
            XCTFail("Expected write failure")
        } catch {}
        let file = await storage.file(value); XCTAssertNotNil(file)
        let recovered = try await storage.recover(library)
        XCTAssertEqual(recovered.records[0].phase, .completed)
    }
    func testFailedRemovalRestoresFileAndSharedArtworkLastOwnerControlsDeletion() async throws {
        let root = try temporary(), storage = DownloadStorage(root: root)
        _ = try await storage.load()
        var one = try record(), two = try record()
        one.artwork = ["poster": "shared.image"]; two.artwork = one.artwork
        try install(one, root: root); try install(two, root: root)
        try await storage.storeArtwork(Data([1]), name: "shared.image")
        var library = DownloadLibrary(); library.records = [one, two]; try await storage.save(library)
        let failing = DownloadStorage(
            root: root,
            repository: DownloadRepository(
                url: root.appendingPathComponent("index.json"),
                write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }))
        do { _ = try await failing.remove([one.id], from: library); XCTFail("Expected write failure") } catch
        {}
        let restored = await storage.file(one); XCTAssertNotNil(restored)
        let remaining = try await storage.remove([one.id], from: library)
        let state = await storage.diskState(); XCTAssertTrue(state.artwork.contains("shared.image"))
        _ = try await storage.remove([two.id], from: remaining)
        let empty = await storage.diskState(); XCTAssertFalse(empty.artwork.contains("shared.image"))
    }
    func testExportProvidesReadableNameWithoutDuplicatingTheVideoAndCleansUp() async throws {
        let root = try temporary(), storage = DownloadStorage(root: root)
        _ = try await storage.load()
        let value = try record(episode: 2); try install(value, root: root)
        let exported = try await storage.export(value)
        XCTAssertEqual(exported.lastPathComponent, "A   Show S01E02.mkv")
        XCTAssertEqual(try Data(contentsOf: exported), bytes())
        let original = root.appendingPathComponent("Media").appendingPathComponent(value.fileName!)
        let first =
            try FileManager.default.attributesOfItem(atPath: exported.path)[.systemFileNumber] as? NSNumber
        let second =
            try FileManager.default.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber
        XCTAssertEqual(first, second)
        await storage.finishExport(exported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testRecoveryUsesValidatedStagingSizeInsteadOfOldProviderEstimate() async throws {
        let root = try temporary(), storage = DownloadStorage(root: root)
        _ = try await storage.load()
        var value = try record(); value.phase = .downloading; value.expectedBytes = 100
        let key = DownloadTaskKey(id: value.id, attempt: value.attempt)
        let staged = root.appendingPathComponent("Incoming").appendingPathComponent(
            key.id.uuidString + "-" + key.attempt.uuidString)
        try bytes().write(to: staged)
        var library = DownloadLibrary(); library.records = [value]
        let recovered = try await storage.recover(library)
        XCTAssertEqual(recovered.records[0].phase, .completed)
        XCTAssertEqual(recovered.records[0].receivedBytes, 8)
    }

    func testVersionOneIndexAndOpaqueResumeDataRemainReadableWithoutMigration() async throws {
        let root = try temporary(), storage = DownloadStorage(root: root)
        _ = try await storage.load()
        var library = DownloadLibrary(), value = try record(); value.phase = .paused;
        value.resumeData = Data([9, 8, 7])
        library.records = [value]; try await storage.save(library)
        let loaded = try await storage.load()
        XCTAssertEqual(loaded.version, 1); XCTAssertEqual(loaded.records[0].resumeData, value.resumeData)
    }
}
