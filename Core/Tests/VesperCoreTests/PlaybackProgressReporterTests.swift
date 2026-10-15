import XCTest
@testable import VesperCore

final class PlaybackProgressReporterTests: XCTestCase {
    private func timeline(_ elapsed: Double, seekable: Bool = true) -> PlaybackTimeline {
        PlaybackTimeline(elapsed: elapsed, duration: 1000, isSeekable: seekable)
    }

    func testPeriodicCheckpointsAreThrottledAndExplicitCheckpointsAreImmediate() {
        var reporter = PlaybackProgressReporter()
        XCTAssertNotNil(reporter.checkpoint(timeline: timeline(100), ended: false, force: false, now: 0))
        XCTAssertNil(reporter.checkpoint(timeline: timeline(101), ended: false, force: false, now: 14))
        XCTAssertNotNil(reporter.checkpoint(timeline: timeline(102), ended: false, force: false, now: 15))
        XCTAssertNotNil(reporter.checkpoint(timeline: timeline(103), ended: false, force: true, now: 16))
        XCTAssertNil(reporter.checkpoint(timeline: timeline(103), ended: false, force: true, now: 17))
    }

    func testCompletionTransitionsAreReportedInBothDirections() {
        var reporter = PlaybackProgressReporter()
        XCTAssertNotNil(reporter.checkpoint(timeline: timeline(949), ended: false, force: false, now: 0))
        XCTAssertEqual(
            reporter.checkpoint(timeline: timeline(950), ended: false, force: false, now: 1)?.isComplete, true
        )
        XCTAssertEqual(
            reporter.checkpoint(timeline: timeline(500), ended: false, force: false, now: 2)?.isComplete,
            false)
        XCTAssertNil(reporter.checkpoint(timeline: timeline(501), ended: false, force: false, now: 3))
    }

    func testUnseekableAndOpeningFramesDoNotProduceProgress() {
        var reporter = PlaybackProgressReporter()
        XCTAssertNil(
            reporter.checkpoint(timeline: timeline(100, seekable: false), ended: false, force: true, now: 0))
        XCTAssertNil(reporter.checkpoint(timeline: timeline(4), ended: false, force: true, now: 0))
        XCTAssertNotNil(reporter.checkpoint(timeline: timeline(5), ended: false, force: false, now: 0))
    }

    func testEarlyEndProducesCompletionAndFreshReporterStartsImmediately() {
        var reporter = PlaybackProgressReporter()
        XCTAssertEqual(
            reporter.checkpoint(timeline: timeline(1), ended: true, force: false, now: 0)?.isComplete, true)
        reporter = PlaybackProgressReporter()
        XCTAssertNotNil(reporter.checkpoint(timeline: timeline(100), ended: false, force: false, now: 1))
    }
}
