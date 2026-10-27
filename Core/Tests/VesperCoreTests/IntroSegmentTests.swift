import XCTest
@testable import VesperCore

@MainActor final class IntroSegmentTests: XCTestCase {
    func testIdentityAndIntervalValidation() {
        XCTAssertNil(IntroEpisode(imdbID: "unknown", season: 1, episode: 1))
        XCTAssertNil(IntroEpisode(imdbID: "tt123", season: -1, episode: 1))
        XCTAssertNil(IntroEpisode(imdbID: "tt123", season: 0, episode: 0))
        XCTAssertNotNil(IntroEpisode(imdbID: "tt123", season: 0, episode: 1))
        for start in [-1, Double.nan, Double.infinity] {
            XCTAssertNil(IntroSegment(startMilliseconds: start, endMilliseconds: 60000))
        }
        for end in [0, -1, Double.nan, Double.infinity] {
            XCTAssertNil(IntroSegment(startMilliseconds: 0, endMilliseconds: end))
        }
    }

    func testButtonBoundariesRewindAndOutOfDurationTimestamps() async throws {
        let intro = try XCTUnwrap(IntroSegment(startMilliseconds: 10000, endMilliseconds: 60000))
        func target(_ elapsed: Double, duration: Double = 100, seekable: Bool = true) -> Double? {
            intro.seekFraction(in: .init(elapsed: elapsed, duration: duration, isSeekable: seekable))
        }
        XCTAssertNil(target(9.9))
        XCTAssertEqual(target(10), 0.6)
        XCTAssertEqual(target(59.9), 0.6)
        XCTAssertNil(target(60))
        XCTAssertEqual(target(20), 0.6)
        XCTAssertNil(target(20, duration: 59))
        XCTAssertNil(target(20, duration: 0))
        XCTAssertNil(target(20, seekable: false))
    }

    func testDisabledMissingAndFailedLookupsDoNotInterruptPlayback() async {
        let controller = IntroSkipController()
        await controller.load(nil)
        XCTAssertNil(controller.segment)
        await controller.load { throw URLError(.timedOut) }
        XCTAssertNil(controller.segment)
    }

    func testSupersededOrCancelledSessionRejectsLateResults() async {
        let controller = IntroSkipController()
        var continuation: CheckedContinuation<IntroSegment?, Never>?
        let old = Task {
            await controller.load {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        let newer = IntroSegment(startMilliseconds: 10000, endMilliseconds: 30000)
        await controller.load { newer }
        continuation?.resume(returning: IntroSegment(startMilliseconds: 0, endMilliseconds: 10000))
        await old.value
        XCTAssertEqual(controller.segment, newer)
        await controller.load {
            controller.cancel()
            return newer
        }
        XCTAssertNil(controller.segment)
    }
}
