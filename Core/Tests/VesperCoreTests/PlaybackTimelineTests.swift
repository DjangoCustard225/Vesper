import XCTest
@testable import VesperCore

final class PlaybackTimelineTests: XCTestCase {
    func testSeekingAndSkippingStayInsideMovie() {
        let timeline = PlaybackTimeline(elapsed: 5, duration: 100, isSeekable: true)
        XCTAssertEqual(timeline.skipTarget(seconds: -10), 0)
        XCTAssertEqual(timeline.skipTarget(seconds: 200), 100)
        XCTAssertEqual(timeline.seekTarget(fraction: 0.4), 40)
        XCTAssertEqual(timeline.seekTarget(fraction: -1), 0)
        XCTAssertEqual(timeline.seekTarget(fraction: 2), 100)
        XCTAssertNil(timeline.seekTarget(fraction: .nan))
        XCTAssertNil(timeline.skipTarget(seconds: .infinity))
    }

    func testLiveAndUnseekableStreamsDoNotExposeSeeking() {
        for duration in [Double(0), -1, .nan, .infinity] {
            let timeline = PlaybackTimeline(elapsed: 20, duration: duration, isSeekable: true)
            XCTAssertFalse(timeline.isSeekable)
            XCTAssertNil(timeline.seekTarget(fraction: 0.5))
            XCTAssertNil(timeline.skipTarget(seconds: 10))
            XCTAssertEqual(timeline.progress, 0)
        }
        XCTAssertFalse(PlaybackTimeline(elapsed: 10, duration: 100, isSeekable: false).isSeekable)
    }

    func testTimingSurvivesInvalidAndLateEngineValues() {
        let ended = PlaybackTimeline(elapsed: 102, duration: 100, isSeekable: true)
        XCTAssertEqual(ended.elapsed, 100)
        XCTAssertEqual(ended.remaining, 0)
        XCTAssertEqual(ended.progress, 1)
        XCTAssertEqual(PlaybackTimeline(elapsed: .nan, duration: 100, isSeekable: true).elapsed, 0)
        XCTAssertEqual(PlaybackTimeline(elapsed: -10, duration: 100, isSeekable: true).elapsed, 0)
    }

    func testClockLabels() {
        XCTAssertEqual(PlaybackTimeline.label(seconds: 0), "0:00")
        XCTAssertEqual(PlaybackTimeline.label(seconds: 65.9), "1:05")
        XCTAssertEqual(PlaybackTimeline.label(seconds: 3665), "1:01:05")
        XCTAssertEqual(PlaybackTimeline.label(seconds: .nan), "0:00")
        XCTAssertEqual(PlaybackTimeline.label(seconds: .infinity), "0:00")
    }
}
