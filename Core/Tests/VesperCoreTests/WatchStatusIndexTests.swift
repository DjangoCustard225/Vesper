import XCTest
@testable import VesperCore

final class WatchStatusIndexTests: XCTestCase {
    private var show: MediaItem {
        var media = MediaItem(id: "tt123", type: "series", name: "Show")
        media.tmdbID = 42
        media.tvdbID = 88
        return media
    }

    private func episode(_ number: Int, season: Int = 1, id: String? = nil) -> Episode {
        Episode(
            id: id ?? "tt123:\(season):\(number)", title: nil, name: nil,
            season: season, episode: number, overview: nil, thumbnail: nil,
            released: nil, streams: nil, runtimeMinutes: nil)
    }

    func testIndexMatchesHistoryAcrossAliasesAndExplicitEpisodeResets() {
        var history = WatchProgress()
        history.setWatched(true, for: show)
        history.setWatched(false, for: show, episode: episode(2))
        history.setWatched(true, for: show, episode: episode(3, season: 0, id: "special-file"))
        let movie = MediaItem(id: "tt123", type: "movie", name: "Movie")
        history.setWatched(true, for: movie)
        let queries = [
            show,
            MediaItem(id: "tmdb:tv:42", type: "series", name: "Show"),
            MediaItem(id: "tvdb:88", type: "series", name: "Show"),
            MediaItem(id: "tt456", type: "series", name: "Unrelated"), movie,
        ]
        let index = WatchStatusIndex(history)
        for media in queries {
            XCTAssertEqual(index.isWatched(media), history.isWatched(media))
            for item in [episode(1), episode(2), episode(3, season: 0, id: "special-file")] {
                XCTAssertEqual(index.isWatched(media, episode: item), history.isWatched(media, episode: item))
            }
        }
    }

    func testCustomPlaybackIDsAndRawIDsCannotCollideWithEpisodeCoordinates() {
        var history = WatchProgress()
        let raw = Episode(
            id: "1:2", title: nil, name: nil, season: nil, episode: nil, overview: nil,
            thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
        history.setWatched(true, for: show, episode: raw)
        let index = WatchStatusIndex(history)
        XCTAssertTrue(index.isWatched(show, episode: raw))
        XCTAssertFalse(index.isWatched(show, episode: episode(2)))
        XCTAssertFalse(index.isWatched(show))
    }

    func testFirstMatchingRecordWinsWhenPlaybackAndCanonicalIDsBothExist() throws {
        let raw = Episode(
            id: "custom-file", title: nil, name: nil, season: 1, episode: 2, overview: nil,
            thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
        let records = [
            WatchRecord(
                media: show, videoID: raw.id, subtitle: nil,
                elapsed: 0, duration: 0, watched: true, updatedAt: Date()),
            WatchRecord(
                media: show, videoID: raw.watchHistoryID(for: show), subtitle: nil,
                elapsed: 0, duration: 0, watched: false, updatedAt: .distantPast),
        ]
        let data = try JSONSerialization.data(withJSONObject: [
            "records": JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
        ])
        let history = try JSONDecoder().decode(WatchProgress.self, from: data)
        XCTAssertTrue(WatchStatusIndex(history).isWatched(show, episode: raw))
        XCTAssertEqual(
            WatchStatusIndex(history).isWatched(show, episode: raw), history.isWatched(show, episode: raw))
    }

    func testLargeImportedHistoryMatchesIndividualEpisodeQueries() {
        let entries = (1...2_000).map { number in
            TraktWatchedEntry(
                media: show, videoID: "tt123:1:\(number)",
                watchedAt: Date(timeIntervalSince1970: Double(number)))
        }
        var history = WatchProgress()
        history.mergeTrakt(entries)
        let index = WatchStatusIndex(history)
        for number in stride(from: 1, through: 2_000, by: 67) {
            let item = episode(number)
            XCTAssertEqual(index.isWatched(show, episode: item), history.isWatched(show, episode: item))
        }
        XCTAssertFalse(index.isWatched(show, episode: episode(2_001)))
    }

    func testIMDbValidationAcceptsOnlyCompleteAsciiIDs() {
        for id in ["tt1", "tt1234567890"] { XCTAssertEqual(MediaIdentity.validIMDb(id), id) }
        for id in ["tt", "TT123", "tt123\n", "tt１２３", "tt123suffix", " tt123"] {
            XCTAssertNil(MediaIdentity.validIMDb(id))
        }
        XCTAssertNil(MediaIdentity.validIMDb(nil))
    }
}
