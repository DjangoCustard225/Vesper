import XCTest
@testable import VesperCore

final class DownloadTests: XCTestCase {
    private func source(_ url: String = "https://files.example/movie.mkv", headers: Bool = false) throws
        -> StreamSource
    {
        let hints: [String: Any]
        if headers {
            hints = ["proxyHeaders": ["request": ["Referer": "private"]]]
        } else {
            hints = ["filename": "movie.mkv", "videoSize": 1000]
        }
        let json: [String: Any] = ["url": url, "name": "1080p", "behaviorHints": hints]
        return try JSONDecoder().decode(StreamSource.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func record(_ index: Int = 1) throws -> DownloadRecord {
        DownloadRecord(
            media: MediaItem(id: "tt\(index)", type: "movie", name: "Movie"), videoID: "tt\(index)",
            subtitle: nil, episode: nil, source: try source(), providerID: nil, fetchedAt: Date())
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testLegacyFanartDetailSnapshotIsIgnoredWhenDecodingDownloads() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record())) as? [String: Any])
        object["detailArtwork"] = [
            "portraitURL": "https://assets.fanart.tv/old.jpg",
            "backgroundURL": "https://assets.fanart.tv/old-wide.jpg",
            "logoURL": "https://assets.fanart.tv/old-logo.png",
        ]
        let restored = try JSONDecoder().decode(
            DownloadRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.detailArtwork?.urls, [])
    }

    func testInterruptedUsenetFinishingWaitsForExplicitResume() throws {
        var download = try record()
        download.phase = .downloading
        download.usenetFinishing = true
        let restored = DownloadPolicy.recovered(download, hasTask: false, hasFile: false)
        XCTAssertEqual(restored.phase, .failed)
        XCTAssertTrue(restored.message?.contains("Resume") == true)
        XCTAssertEqual(restored.attempt, download.attempt)
    }

    func testUsenetSelectionAndPasswordPromptSurviveRestartAndOldRecordsDecode() throws {
        var download = try record()
        download.usenetSelectedFile = "Extracted/Season 1/Episode 1.mkv"
        download.usenetFiles = ["Extracted/Season 1/Episode 1.mkv"]
        download.usenetNeedsPassword = true
        let encoded = try JSONEncoder().encode(download)
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: encoded)
        XCTAssertEqual(restored.usenetSelectedFile, download.usenetSelectedFile)
        XCTAssertEqual(restored.usenetFiles, download.usenetFiles)
        XCTAssertEqual(restored.usenetNeedsPassword, true)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["usenetSelectedFile", "usenetFiles", "usenetNeedsPassword", "usenetFinishing"] {
            legacy.removeValue(forKey: key)
        }
        let old = try JSONDecoder().decode(
            DownloadRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.usenetSelectedFile)
        XCTAssertNil(old.usenetFiles)
        XCTAssertNil(old.usenetNeedsPassword)
    }

    func testDownloadEligibilityUsesActualTransportWithoutRequiringAnExtension() throws {
        XCTAssertEqual(
            try DownloadPolicy.url(for: source("https://files.example/play?token=abc")).host, "files.example")
        for url in [
            "https://files.example/live.m3u8", "https://files.example/live.mpd", "file:///private/movie.mkv",
            "ftp://files.example/movie.mkv",
        ] {
            XCTAssertThrowsError(try DownloadPolicy.url(for: source(url)))
        }
        XCTAssertThrowsError(try DownloadPolicy.url(for: source(), live: true))
        XCTAssertThrowsError(try DownloadPolicy.url(for: source(headers: true)))
        let external = try JSONDecoder().decode(
            StreamSource.self, from: Data(#"{"externalUrl":"https://example.com/watch"}"#.utf8))
        XCTAssertThrowsError(try DownloadPolicy.url(for: external))
    }

    func testResponseValidationRejectsPlaylistsErrorPagesAndUnsuccessfulTransfers() throws {
        for status in [202, 403, 404, 416, 500] {
            XCTAssertThrowsError(try DownloadPolicy.validate(status: status, mime: nil, prefix: Data()))
        }
        for mime in [
            "application/vnd.apple.mpegurl", "application/dash+xml", "text/html", "application/json",
        ] {
            XCTAssertThrowsError(try DownloadPolicy.validate(status: 200, mime: mime, prefix: Data()))
        }
        for prefix in ["#EXTM3U", "  <!DOCTYPE html>", "{\"error\":true}", "[1,2]"] {
            XCTAssertThrowsError(
                try DownloadPolicy.validate(
                    status: 200, mime: "application/octet-stream", prefix: Data(prefix.utf8)))
        }
        XCTAssertNoThrow(
            try DownloadPolicy.validate(
                status: 206, mime: "video/x-matroska", prefix: Data([0x1a, 0x45, 0xdf, 0xa3])))
    }

    func testRangeTotalsAndFileExtensionWorkForOpaqueAndResumedURLs() {
        XCTAssertEqual(
            DownloadPolicy.totalBytes(contentRange: "bytes 0-4095/123456", contentLength: 4096), 123456)
        XCTAssertEqual(
            DownloadPolicy.totalBytes(contentRange: "bytes 8000-9999/10000", contentLength: 2000), 10000)
        XCTAssertNil(DownloadPolicy.totalBytes(contentRange: "bytes 0-4095/*", contentLength: 4096))
        XCTAssertNil(DownloadPolicy.totalBytes(contentRange: nil, contentLength: -1))
        XCTAssertEqual(
            DownloadPolicy.fileExtension(
                url: URL(string: "https://files.example/play")!, filename: "../../Movie.MKV", mime: nil,
                prefix: Data()), "mkv")
        XCTAssertEqual(
            DownloadPolicy.fileExtension(
                url: URL(string: "https://files.example/play")!, filename: nil, mime: nil,
                prefix: Data([0x1a, 0x45, 0xdf, 0xa3])), "mkv")
        XCTAssertFalse(DownloadPolicy.safeName("../movie.mkv"))
        XCTAssertFalse(DownloadPolicy.safeName("path\\movie"))
    }

    func testQueueHonorsTwoSlotsPausedItemsConnectivityAndRetryDelay() throws {
        var values = try (1...5).map(record)
        XCTAssertEqual(DownloadPolicy.next(values).map(\.id), Array(values.prefix(2).map(\.id)))
        values[0].phase = .downloading; values[1].phase = .pausing
        XCTAssertTrue(DownloadPolicy.next(values).isEmpty)
        values[1].phase = .paused
        XCTAssertEqual(DownloadPolicy.next(values).map(\.id), [values[2].id])
        values[2].retryAt = Date().addingTimeInterval(100)
        XCTAssertEqual(DownloadPolicy.next(values).map(\.id), [values[3].id])
        XCTAssertTrue(DownloadPolicy.next(values, networkAllowed: false).isEmpty)
    }

    func testDiskBudgetIncludesConcurrentRemainingBytesAndRejectsOverflow() {
        let reserve = DownloadPolicy.storageReserve
        XCTAssertTrue(DownloadPolicy.hasSpace(available: reserve + 3000, remaining: [1000, 2000]))
        XCTAssertFalse(DownloadPolicy.hasSpace(available: reserve + 2999, remaining: [1000, 2000]))
        XCTAssertFalse(DownloadPolicy.hasSpace(available: Int64.max, remaining: [Int64.max, 100]))
    }

    func testResumeRequiresSameURLNetworkPolicyAndRepresentation() throws {
        var value = try record()
        value.resumeData = Data([1]); value.etag = "version1"; value.expectedBytes = 1000
        XCTAssertTrue(
            DownloadPolicy.canResume(
                value, source: value.source, allowsCellular: false, etag: "version1", modified: nil,
                total: 1000))
        XCTAssertFalse(
            DownloadPolicy.canResume(
                value, source: value.source, allowsCellular: true, etag: "version1", modified: nil,
                total: 1000))
        XCTAssertFalse(
            DownloadPolicy.canResume(
                value, source: value.source, allowsCellular: false, etag: "version2", modified: nil,
                total: 1000))
        XCTAssertFalse(
            DownloadPolicy.canResume(
                value, source: value.source, allowsCellular: false, etag: "version1", modified: nil,
                total: 2000))
        XCTAssertFalse(
            DownloadPolicy.canResume(
                value, source: try source("https://files.example/movie.mkv?token=new"), allowsCellular: false,
                etag: "version1", modified: nil, total: 1000))
        value.etag = nil; value.lastModified = "date"
        XCTAssertTrue(
            DownloadPolicy.canResume(
                value, source: value.source, allowsCellular: false, etag: nil, modified: "date", total: 1000))
    }

    func testRecoveryKeepsLiveTasksAndRestoresInterruptedStatesWithoutInventingCompletion() throws {
        var value = try record(); value.phase = .downloading
        XCTAssertEqual(DownloadPolicy.recovered(value, hasTask: true, hasFile: false).phase, .downloading)
        XCTAssertEqual(DownloadPolicy.recovered(value, hasTask: false, hasFile: false).phase, .queued)
        value.phase = .pausing
        XCTAssertEqual(DownloadPolicy.recovered(value, hasTask: false, hasFile: false).phase, .paused)
        value.phase = .completed; value.fileName = "local.mkv"
        XCTAssertEqual(DownloadPolicy.recovered(value, hasTask: false, hasFile: true).phase, .completed)
        XCTAssertEqual(DownloadPolicy.recovered(value, hasTask: false, hasFile: false).phase, .failed)
    }

    func testPlaybackAndExportBothProtectTheSameFileUntilTheirLastLeaseEnds() {
        let id = UUID(); var leases = DownloadFileLeases()
        leases.acquire([id]); leases.acquire([id]); leases.release([id])
        XCTAssertTrue(leases.ids.contains(id))
        leases.release([id]); leases.release([id])
        XCTAssertTrue(leases.ids.isEmpty)
    }

    func testSignedURLDuplicatesDoNotMergeDifferentReleases() throws {
        let media = MediaItem(id: "tt1", type: "movie", name: "Movie")
        let one = DownloadRecord(
            media: media, videoID: "tt1", subtitle: nil, episode: nil,
            source: try source("https://files.example/movie.mkv?token=old"), providerID: nil,
            fetchedAt: Date())
        let two = DownloadRecord(
            media: media, videoID: "tt1", subtitle: nil, episode: nil,
            source: try source("https://files.example/movie.mkv?token=new"), providerID: nil,
            fetchedAt: Date())
        let other = DownloadRecord(
            media: media, videoID: "tt1", subtitle: nil, episode: nil,
            source: try source("https://files.example/other.mkv?token=new"), providerID: nil,
            fetchedAt: Date())
        XCTAssertTrue(one.duplicates(two)); XCTAssertFalse(one.duplicates(other))
    }

    func testPersistenceRetainsRecoveryDataArtworkAndDescriptionsButNotEmbeddedStreams() throws {
        let root = try temporary(), repo = DownloadRepository(url: root.appendingPathComponent("index.json"))
        var library = DownloadLibrary(), value = try record()
        value.media.description = "Available offline"; value.resumeData = Data([1, 2, 3]);
        value.artwork = ["https://images.example/poster": "cached.image"]
        library.records = [value]; library.allowsCellular = true
        try repo.save(library)
        let loaded = try repo.load()
        XCTAssertEqual(loaded.records.first?.resumeData, value.resumeData)
        XCTAssertEqual(loaded.records.first?.media.description, "Available offline")
        XCTAssertTrue(loaded.allowsCellular)
        XCTAssertEqual(loaded.records.first?.artwork, value.artwork)
    }

    func testCorruptFutureAndUnsafeIndexesAreNeverOverwrittenByLoading() throws {
        let root = try temporary(), url = root.appendingPathComponent("index.json"),
            repo = DownloadRepository(url: url)
        let damaged = Data("broken".utf8); try damaged.write(to: url)
        XCTAssertThrowsError(try repo.load()); XCTAssertEqual(try Data(contentsOf: url), damaged)
        var future = DownloadLibrary(); future.version = 999
        let data = try JSONEncoder().encode(future); try data.write(to: url)
        XCTAssertThrowsError(try repo.load()); XCTAssertEqual(try Data(contentsOf: url), data)
        var invalid = DownloadLibrary(), value = try record(); value.fileName = "../escape.mkv";
        invalid.records = [value]
        XCTAssertThrowsError(try repo.save(invalid))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testFailedIndexWritePreservesThePreviouslySavedQueue() throws {
        let root = try temporary(), url = root.appendingPathComponent("index.json"),
            repo = DownloadRepository(url: url)
        var saved = DownloadLibrary(); saved.records = [try record()]; try repo.save(saved)
        let failing = DownloadRepository(url: url, write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        var proposed = saved; proposed.records = []
        XCTAssertThrowsError(try failing.save(proposed))
        XCTAssertEqual(try repo.load().records.map(\.id), saved.records.map(\.id))
    }
}
