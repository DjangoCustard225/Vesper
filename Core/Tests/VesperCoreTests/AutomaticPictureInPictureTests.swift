import XCTest
@testable import VesperCore

final class AutomaticPictureInPictureTests: XCTestCase {
    func testStartingAndStoppingKeepTheSurfacePinnedUntilTheirCompletionCallbacks() {
        var policy = AutomaticPictureInPicture()
        policy.willStart()
        XCTAssertEqual(policy.state, .starting)
        XCTAssertTrue(policy.state.isPresented)
        XCTAssertTrue(policy.state.isTransitioning)
        XCTAssertFalse(policy.graceExpired())
        XCTAssertEqual(policy.backgrounded(eligible: false, externalPlayback: false), .keepPlaying)
        policy.started()
        XCTAssertFalse(policy.state.isTransitioning)
        policy.willStop()
        XCTAssertEqual(policy.state, .stopping)
        XCTAssertTrue(policy.state.isPresented)
        XCTAssertTrue(policy.stopped())
        XCTAssertFalse(policy.state.isPresented)
    }

    func testForegroundAndWillStopCannotClearPendingRestoration() {
        var policy = AutomaticPictureInPicture()
        policy.restoring()
        policy.foregrounded()
        policy.willStop()
        XCTAssertEqual(policy.state, .restoring)
        XCTAssertFalse(policy.stopped())
    }

    func testFailedRestorationKeepsPiPActiveAndAllowsBackgroundCloseToPause() {
        var policy = AutomaticPictureInPicture()
        policy.restoring()
        policy.restorationFailed()
        XCTAssertEqual(policy.state, .active)
        XCTAssertTrue(policy.stopped())
        policy.restorationFailed()
        XCTAssertEqual(policy.state, .inactive)
    }
    func testBackgroundNotificationDoesNotCancelPendingAutomaticEntry() {
        var policy = AutomaticPictureInPicture()
        XCTAssertEqual(policy.backgrounded(eligible: true, externalPlayback: false), .waitForSystem)
        XCTAssertEqual(policy.backgrounded(eligible: true, externalPlayback: false), .waitForSystem)
        policy.started()
        XCTAssertEqual(policy.state, .active)
        XCTAssertFalse(policy.graceExpired())
        XCTAssertEqual(policy.backgrounded(eligible: true, externalPlayback: false), .keepPlaying)
    }
    func testSystemCanStartPiPBeforeBackgroundNotificationArrives() {
        var policy = AutomaticPictureInPicture()
        policy.started()
        XCTAssertEqual(policy.backgrounded(eligible: false, externalPlayback: false), .keepPlaying)
        XCTAssertFalse(policy.graceExpired())
    }
    func testDeclinedAutomaticEntryPausesOnlyAfterGraceExpires() {
        var policy = AutomaticPictureInPicture()
        XCTAssertEqual(policy.backgrounded(eligible: true, externalPlayback: false), .waitForSystem)
        XCTAssertTrue(policy.graceExpired())
        XCTAssertEqual(policy.state, .inactive)
        XCTAssertFalse(policy.graceExpired())
    }
    func testForegroundReturnCancelsPendingPause() {
        var policy = AutomaticPictureInPicture()
        _ = policy.backgrounded(eligible: true, externalPlayback: false)
        policy.foregrounded()
        XCTAssertFalse(policy.graceExpired())
        XCTAssertEqual(policy.state, .inactive)
    }
    func testClosingPiPInBackgroundPausesPlayback() {
        var policy = AutomaticPictureInPicture()
        policy.started()
        XCTAssertTrue(policy.stopped())
        XCTAssertEqual(policy.state, .inactive)
    }
    func testRestoringDoesNotPauseBeforeAppBecomesActiveAndDoesNotLeaveStaleState() {
        var policy = AutomaticPictureInPicture()
        policy.started(); policy.restoring()
        XCTAssertFalse(policy.stopped())
        XCTAssertEqual(policy.state, .inactive)
        policy.foregrounded()
        XCTAssertEqual(policy.backgrounded(eligible: true, externalPlayback: false), .waitForSystem)
    }
    func testForegroundMayArriveBeforeRestorationFinishes() {
        var policy = AutomaticPictureInPicture()
        policy.started(); policy.foregrounded(); policy.restoring()
        XCTAssertFalse(policy.stopped())
        XCTAssertEqual(policy.state, .inactive)
    }
    func testIneligibleVideoDoesNotKeepPlayingInBackground() {
        var policy = AutomaticPictureInPicture()
        XCTAssertEqual(policy.backgrounded(eligible: false, externalPlayback: false), .pause)
        XCTAssertEqual(policy.state, .inactive)
    }
    func testAirPlayDoesNotDependOnPiPEligibility() {
        var policy = AutomaticPictureInPicture()
        XCTAssertEqual(policy.backgrounded(eligible: false, externalPlayback: true), .keepPlaying)
        XCTAssertEqual(policy.state, .inactive)
    }
    func testResetIgnoresStaleGraceTimeout() {
        var policy = AutomaticPictureInPicture()
        _ = policy.backgrounded(eligible: true, externalPlayback: false)
        policy.reset()
        XCTAssertFalse(policy.graceExpired())
        XCTAssertEqual(policy.state, .inactive)
    }
}
