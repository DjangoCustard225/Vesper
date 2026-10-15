import XCTest
@testable import VesperCore

final class WatchProgressTests: XCTestCase {
    private func media(_ id: String = "tt123", type: String = "movie") -> MediaItem {
        MediaItem(id: id, type: type, name: "Title")
    }

    func testMovieResumeCompletionAndExplicitUnwatched() {
        let movie = media()
        var state = WatchProgress()
        state.record(media: movie, videoID: movie.id, subtitle: nil, elapsed: 300, duration: 1000)
        XCTAssertEqual(state.resumePosition(for: movie, videoID: movie.id), 300)
        XCTAssertEqual(state.continueWatching.count, 1)
        state.record(media: movie, videoID: movie.id, subtitle: nil, elapsed: 950, duration: 1000)
        XCTAssertTrue(state.isWatched(movie))
        XCTAssertTrue(state.continueWatching.isEmpty)
        XCTAssertEqual(state.resumePosition(for: movie, videoID: movie.id), 0)
        state.setWatched(false, for: movie)
        XCTAssertFalse(state.isWatched(movie))
        XCTAssertTrue(state.records.isEmpty)
    }

    func testActualEndCompletesEvenWhenDurationEstimateIsLonger() {
        let movie = media()
        var state = WatchProgress()
        state.record(
            media: movie, videoID: movie.id, subtitle: nil, elapsed: 800, duration: 1000, ended: true)
        XCTAssertTrue(state.isWatched(movie))
    }

    func testEpisodesHaveIndependentProgressAndOnlyOneHomeEntryPerShow() {
        let show = media(type: "series")
        var state = WatchProgress()
        state.record(
            media: show, videoID: "tt123:1:1", subtitle: "Episode 1", elapsed: 100, duration: 1000,
            now: Date(timeIntervalSince1970: 1))
        state.record(
            media: show, videoID: "tt123:2:3", subtitle: "Episode 3", elapsed: 200, duration: 1000,
            now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(state.resumePosition(for: show, videoID: "tt123:1:1"), 100)
        XCTAssertEqual(state.resumePosition(for: show, videoID: "tt123:2:3"), 200)
        XCTAssertEqual(state.continueWatching.count, 1)
        XCTAssertEqual(state.continueWatching.first?.season, 2)
        XCTAssertEqual(state.continueWatching.first?.subtitle, "Episode 3")
        state.record(media: show, videoID: "tt123:2:3", subtitle: nil, elapsed: 960, duration: 1000)
        XCTAssertFalse(state.isWatched(show), "Finishing one episode must not mark the whole series watched")
        XCTAssertEqual(state.resumePosition(for: show, videoID: "tt123:2:3"), 0)
    }

    func testEnrichedIdentityResumesAndReplacesTheSameEpisode() {
        let tmdb = media("tmdb:tv:42", type: "series")
        var enriched = media(type: "series")
        enriched.tmdbID = 42
        var state = WatchProgress()
        state.record(media: tmdb, videoID: "tmdb:tv:42:3:2", subtitle: nil, elapsed: 100, duration: 1000)
        XCTAssertEqual(state.resumePosition(for: enriched, videoID: "tt123:3:2"), 100)
        XCTAssertEqual(state.continueWatching.first?.playbackID(for: enriched), "tt123:3:2")
        state.record(media: enriched, videoID: "tt123:3:2", subtitle: nil, elapsed: 200, duration: 1000)
        XCTAssertEqual(state.records.count, 1)
        XCTAssertEqual(state.resumePosition(for: tmdb, videoID: "tmdb:tv:42:3:2"), 200)
    }

    func testCustomEpisodeIDsAndSpecialsAreRetained() {
        let show = media("custom", type: "series")
        var state = WatchProgress()
        state.record(media: show, videoID: "provider-episode", subtitle: nil, elapsed: 20, duration: 100)
        XCTAssertEqual(state.continueWatching.first?.playbackID(for: show), "provider-episode")
        state.record(media: show, videoID: "custom:0:1", subtitle: nil, elapsed: 20, duration: 100)
        XCTAssertEqual(state.continueWatching.first?.season, 0)
        XCTAssertEqual(state.records.count, 2)
    }

    func testManualSeriesMarkClearsAllEpisodeProgressAndUnwatchedRestarts() {
        let show = media(type: "series")
        var state = WatchProgress()
        for episode in 1...3 {
            state.record(
                media: show, videoID: "tt123:1:\(episode)", subtitle: nil, elapsed: 100, duration: 1000)
        }
        state.setWatched(true, for: show)
        XCTAssertTrue(state.isWatched(show))
        XCTAssertEqual(state.records.count, 1)
        XCTAssertTrue(state.continueWatching.isEmpty)
        state.setWatched(false, for: show)
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertEqual(state.resumePosition(for: show, videoID: "tt123:1:1"), 0)
    }

    func testInvalidLiveAndNegligiblePlaybackNeverCreateRecords() {
        var state = WatchProgress()
        let movie = media()
        for (position, duration) in [(Double.nan, 100), (10, Double.infinity), (-10, 100), (10, 0), (4, 100)]
        {
            XCTAssertFalse(
                state.record(
                    media: movie, videoID: movie.id, subtitle: nil, elapsed: position, duration: duration))
        }
        let live = media(type: "tv")
        XCTAssertFalse(state.record(media: live, videoID: live.id, subtitle: nil, elapsed: 20, duration: 100))
        var liveMovie = movie

        liveMovie.behaviorHints = MediaHints(defaultVideoId: nil, isLive: true, hasScheduledVideos: nil)
        XCTAssertFalse(
            state.record(media: liveMovie, videoID: movie.id, subtitle: nil, elapsed: 20, duration: 100))
        XCTAssertTrue(state.records.isEmpty)
    }

    func testSavedMetadataOmitsEmbeddedStreams() throws {
        var movie = media()
        movie.videos = [
            Episode(
                id: "private-playable-url", title: nil, name: nil, season: nil, episode: nil,
                overview: nil, thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
        ]
        var state = WatchProgress()
        state.record(media: movie, videoID: movie.id, subtitle: nil, elapsed: 20, duration: 100)
        let data = try JSONEncoder().encode(state)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-playable-url"))
        XCTAssertNil(state.records.first?.media.videos)
    }

    func testContinueWatchingIsSortedByMostRecentPlayback() {
        var state = WatchProgress()
        for index in 1...3 {
            let movie = media("tt\(index)")
            state.record(
                media: movie, videoID: movie.id, subtitle: nil, elapsed: 20, duration: 100,
                now: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(state.continueWatching.map(\.media.id), ["tt3", "tt2", "tt1"])
    }
}

final class WatchProgressRepositoryTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()

        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var repository: WatchProgressRepository {
        WatchProgressRepository(url: directory.appendingPathComponent("progress.json"))
    }

    private func state(_ position: Double) -> WatchProgress {
        var result = WatchProgress()
        result.record(
            media: MediaItem(id: "tt1", type: "movie", name: "Movie"), videoID: "tt1", subtitle: nil,
            elapsed: position, duration: 1000)
        return result
    }

    func testFreshAndRestartedRepository() throws {
        XCTAssertTrue(try repository.load().state.records.isEmpty)
        try repository.save(state(100))
        XCTAssertEqual(try repository.load().state.records.first?.elapsed, 100)
        XCTAssertFalse(try repository.load().recovered)
    }

    private func addLegacySource(to url: URL) throws {
        var envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var progress = try XCTUnwrap(envelope["progress"] as? [String: Any])
        var records = try XCTUnwrap(progress["records"] as? [[String: Any]])
        records[0]["lastStream"] = [
            "providerKey": "retired-provider", "exactKey": "retired-source",
            "stableKey": "retired-stable", "fileIdentity": ["filenameKey": "retired-file"],
        ]
        progress["records"] = records
        envelope["progress"] = progress
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
    }

    func testRetiredSourcesArePurgedFromPrimaryAndBackupWithoutChangingProgress() throws {
        try repository.save(state(100))
        try repository.save(state(200))
        try addLegacySource(to: repository.url)
        try addLegacySource(to: repository.backupURL)
        let loaded = try repository.load()
        XCTAssertFalse(loaded.recovered)
        XCTAssertEqual(
            loaded.state.resumePosition(
                for: MediaItem(id: "tt1", type: "movie", name: "Movie"), videoID: "tt1"), 200)
        XCTAssertEqual(loaded.state.continueWatching.count, 1)
        for (file, expected) in [(repository.url, 200.0), (repository.backupURL, 100.0)] {
            let data = try Data(contentsOf: file)
            XCTAssertEqual(try WatchProgressRepository.decode(data).records.first?.elapsed, expected)
            for removed in ["lastStream", "retired-provider", "retired-source", "retired-file"] {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(removed))
            }
        }
    }

    func testLegacyBackupRecoveryPurgesTheSourceAndPreservesCorruptPrimary() throws {
        try repository.save(state(100))
        try repository.save(state(200))
        try addLegacySource(to: repository.backupURL)
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: repository.url)
        let loaded = try repository.load()
        XCTAssertTrue(loaded.recovered)
        XCTAssertEqual(loaded.state.records.first?.elapsed, 100)
        XCTAssertEqual(try Data(contentsOf: repository.url), corrupt)
        XCTAssertFalse(try String(contentsOf: repository.backupURL, encoding: .utf8).contains("lastStream"))
    }

    func testSavingLegacyProgressDoesNotCarrySourceIdentifiersIntoTheBackup() throws {
        try repository.save(state(100))
        try addLegacySource(to: repository.url)
        try repository.save(state(200))
        XCTAssertEqual(
            try WatchProgressRepository.decode(Data(contentsOf: repository.backupURL)).records.first?.elapsed,
            100)
        XCTAssertFalse(try String(contentsOf: repository.backupURL, encoding: .utf8).contains("lastStream"))
    }

    func testFailedSourceCleanupDoesNotReplacePrimaryWithOlderBackup() throws {
        try repository.save(state(100))
        try repository.save(state(200))
        try addLegacySource(to: repository.url)
        let original = try Data(contentsOf: repository.url)
        let failing = WatchProgressRepository(url: repository.url) { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }
        XCTAssertThrowsError(try failing.load())
        XCTAssertEqual(try Data(contentsOf: repository.url), original)
        XCTAssertEqual(try WatchProgressRepository.decode(original).records.first?.elapsed, 200)
    }

    func testRecoveryPreservesTheDamagedFile() throws {
        try repository.save(state(100))
        try repository.save(state(200))
        try Data("corrupt".utf8).write(to: repository.url)
        let loaded = try repository.load()
        XCTAssertTrue(loaded.recovered)
        XCTAssertEqual(loaded.state.records.first?.elapsed, 100)
        try repository.save(loaded.state)
        let preserved = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.contains("corrupt-") })
        XCTAssertEqual(try String(contentsOf: preserved, encoding: .utf8), "corrupt")
    }

    func testFutureVersionIsNeverOverwrittenEvenWithValidBackup() throws {
        try repository.save(state(100))
        try repository.save(state(200))
        let future = Data("{\"version\":2,\"progress\":{\"records\":[]}}".utf8)
        try future.write(to: repository.url)
        XCTAssertThrowsError(try repository.load())
        XCTAssertThrowsError(try repository.save(state(300)))
        XCTAssertEqual(try Data(contentsOf: repository.url), future)
    }

    func testFailedWriteRetainsPreviousProgress() throws {
        try repository.save(state(100))
        let url = repository.url
        let failing = WatchProgressRepository(url: url) { data, destination in
            if destination == url { throw CocoaError(.fileWriteOutOfSpace) }
            try PersistenceIO.write(data, destination)
        }
        XCTAssertThrowsError(try failing.save(state(200)))
        XCTAssertEqual(try repository.load().state.records.first?.elapsed, 100)
    }

    func testInvalidProgressIsRejectedWithoutOverwritingFiles() throws {
        try repository.save(state(100))
        let data = try Data(contentsOf: repository.url)
        let invalid = Data(
            String(decoding: data, as: UTF8.self).replacingOccurrences(
                of: "\"elapsed\":100", with: "\"elapsed\":-100"
            ).utf8)
        XCTAssertThrowsError(try WatchProgressRepository.decode(invalid))
        try Data("broken".utf8).write(to: repository.url)
        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try String(contentsOf: repository.url, encoding: .utf8), "broken")
    }
}
