import Foundation
import XCTest
@testable import VesperCore

final class OfflineLaunchTests: XCTestCase {
    func testOfflineLaunchWaitsForStatusAndDoesNotInterruptPlaybackOnReconnection() {
        var launch = OfflineLaunch()
        XCTAssertEqual(launch.mode, .waiting)
        launch.observe(available: false)
        XCTAssertEqual(launch.mode, .offline)
        launch.observe(available: true)
        XCTAssertEqual(launch.mode, .offline)
        launch.goOnline(available: false)
        XCTAssertEqual(launch.mode, .offline)
        launch.goOnline(available: true)
        XCTAssertEqual(launch.mode, .online)
        launch.observe(available: false)
        XCTAssertEqual(launch.mode, .online)
    }
    func testOnlineLaunchAndLibraryMergesDownloadsWithoutDuplicatingTitles() throws {
        var launch = OfflineLaunch(); launch.observe(available: true)
        XCTAssertEqual(launch.mode, .online)
        let movie = MediaItem(id: "tt0000001", type: "movie", name: "Movie")
        let show = MediaItem(id: "tt0000002", type: "series", name: "Show")
        let source = try JSONDecoder().decode(
            StreamSource.self, from: Data(#"{"url":"https://example.com/file.mp4"}"#.utf8))
        var completed = DownloadRecord(
            media: movie, videoID: movie.id, subtitle: nil, episode: nil, source: source, providerID: nil,
            fetchedAt: Date())
        completed.phase = .completed
        let pending = DownloadRecord(
            media: show, videoID: show.id, subtitle: nil, episode: nil, source: source, providerID: nil,
            fetchedAt: Date())
        XCTAssertEqual(
            LibraryDownloadPresentation.titles(
                saved: [movie], downloads: [completed, pending], offlineOnly: false
            ).map(\.id), [movie.id, show.id])
        XCTAssertEqual(
            LibraryDownloadPresentation.titles(
                saved: [show], downloads: [completed, pending], offlineOnly: true
            ).map(\.id), [movie.id])
    }
}
