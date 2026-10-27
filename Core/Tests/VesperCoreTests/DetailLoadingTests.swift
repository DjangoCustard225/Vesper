import XCTest
@testable import VesperCore

private actor DetailGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false

    func pause() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor final class DetailLoadingTests: XCTestCase {
    private func episode(_ id: String, season: Int) -> Episode {
        Episode(
            id: id, title: id, name: nil, season: season, episode: 1,
            overview: nil, thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
    }

    private func details() -> MetadataEnrichment {
        MetadataEnrichment(
            id: 42, mediaType: "tv", overview: nil, tagline: nil, posterURL: nil,
            backdropURL: nil, titleLogoURL: nil, releaseYear: nil, runtimeMinutes: nil,
            genres: [], cast: [], directors: [], directorPeople: [], crew: nil,
            creators: [], rating: nil, voteCount: nil, imdbID: nil, seasons: [1, 2])
    }

    private func waitForGate(_ gate: DetailGate, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await gate.waiting { return }
            await Task.yield()
        }
        XCTFail("The request did not reach its gate", file: file, line: line)
    }

    func testCancelledMetadataDoesNotPublishAndClearsLoading() async {
        let item = MediaItem(id: "tt1234567", type: "movie", name: "Movie")
        let controller = DetailLoadingController(item: item), gate = DetailGate()
        let request = Task {
            await controller.load { item in
                await gate.pause()
                var stale = item
                stale.description = "Cancelled"
                return (stale, nil)
            }
        }
        await waitForGate(gate)
        request.cancel()
        await gate.release()
        await request.value
        XCTAssertFalse(controller.loading)
        XCTAssertNil(controller.full)
        XCTAssertNil(controller.error)
    }

    func testCancelledEnrichmentAndSeasonKeepExistingDetailsAndClearLoading() async {
        let item = MediaItem(id: "tt1234567", type: "series", name: "Series")
        let controller = DetailLoadingController(item: item), enrichment = details()
        await controller.load(metadata: { ($0, nil) }, enrich: { _ in enrichment })
        await controller.loadSeason { [self] _, _, _ in [episode("existing", season: 1)] }
        await controller.refreshEnrichment { _ in throw CancellationError() }
        await controller.loadSeason(preserveExisting: true) { _, _, _ in throw CancellationError() }
        XCTAssertFalse(controller.enriching)
        XCTAssertFalse(controller.seasonLoading)
        XCTAssertEqual(controller.enrichment, enrichment)
        XCTAssertEqual(controller.episodes.map(\.id), ["existing"])
        XCTAssertNil(controller.metadataError)
        XCTAssertNil(controller.seasonError)
    }

    func testCancelledOldEnrichmentCannotClearNewRequestsLoadingState() async {
        let item = MediaItem(id: "tt1234567", type: "series", name: "Series")
        let controller = DetailLoadingController(item: item), oldGate = DetailGate(), newGate = DetailGate()
        await controller.load(metadata: { ($0, nil) })
        let old = Task {
            await controller.refreshEnrichment { _ in
                await oldGate.pause()
                throw CancellationError()
            }
        }
        await waitForGate(oldGate)
        let new = Task {
            await controller.refreshEnrichment { [self] _ in
                await newGate.pause()
                return details()
            }
        }
        await waitForGate(newGate)
        old.cancel()
        await oldGate.release()
        await old.value
        XCTAssertTrue(controller.enriching)
        await newGate.release()
        await new.value
        XCTAssertFalse(controller.enriching)
        XCTAssertEqual(controller.enrichment, details())
    }

    func testMoviePlaybackStartsOnceAfterMetadata() async {
        let item = MediaItem(id: "tt1234567", type: "movie", name: "Movie")
        let controller = DetailLoadingController(item: item, startPlayback: true)
        await controller.load(metadata: { ($0, nil) })
        XCTAssertFalse(controller.loading)
        XCTAssertEqual(controller.requestedPlayback()?.id, item.playbackID)
        XCTAssertNil(controller.requestedPlayback())
    }

    func testSeriesWaitsForAnEpisodeBeforeAutomaticPlayback() async {
        let item = MediaItem(id: "tt1234567", type: "series", name: "Series")
        let controller = DetailLoadingController(item: item, startPlayback: true)
        await controller.load(metadata: { ($0, nil) })
        XCTAssertNil(controller.requestedPlayback())
        var populated = item
        populated.videos = [
            Episode(
                id: "tt1234567:1:1", title: "Pilot", name: nil, season: 1, episode: 1,
                overview: nil, thumbnail: nil, released: nil, streams: nil, runtimeMinutes: nil)
        ]
        await controller.load(metadata: { _ in (populated, nil) })
        XCTAssertEqual(controller.season, 1)
        XCTAssertEqual(controller.requestedPlayback()?.id, "tt1234567:1:1")
    }

    func testReplacedMetadataRequestCannotOverwriteNewerResult() async {
        let item = MediaItem(id: "tt1234567", type: "movie", name: "Original")
        let controller = DetailLoadingController(item: item), gate = DetailGate()
        let first = Task {
            await controller.load(metadata: { item in
                await gate.pause()
                var old = item
                old.description = "Old"
                return (old, nil)
            })
        }
        await waitForGate(gate)
        await controller.load(metadata: { item in
            var new = item
            new.description = "New"
            return (new, nil)
        })
        await gate.release()
        await first.value
        XCTAssertEqual(controller.media.description, "New")
    }

    func testLateSeasonResultCannotReplaceNewSelection() async {
        let item = MediaItem(id: "tt1234567", type: "series", name: "Series")
        let controller = DetailLoadingController(item: item), gate = DetailGate()
        let enrichment = details()
        await controller.load(metadata: { ($0, nil) }, enrich: { _ in enrichment })
        XCTAssertEqual(controller.season, 1)
        let first = Task {
            await controller.loadSeason { [self] _, _, _ in
                await gate.pause()
                return [episode("old", season: 1)]
            }
        }
        await waitForGate(gate)
        controller.season = 2
        await controller.loadSeason { [self] _, _, _ in [episode("new", season: 2)] }
        await gate.release()
        await first.value
        XCTAssertEqual(controller.episodes.map(\.id), ["new"])
    }
}
