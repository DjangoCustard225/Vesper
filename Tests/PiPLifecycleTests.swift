import Foundation

@MainActor final class UIApplication {
    enum State { case active, background }
    static let shared = UIApplication()
    var applicationState = State.background
}

@MainActor final class AVPictureInPictureController {
    var isPictureInPicturePossible = true
    var isPictureInPictureActive = false
    var canStartPictureInPictureAutomaticallyFromInline = true
    var stops = 0
    func stopPictureInPicture() { stops += 1 }
}

@MainActor final class PlaybackOwner {
    var isPlaying = true
    var hasEnded = false
    var error: String?
    var externalPlaybackActive = false
    var pauses = 0
    var pip = false
    var pendingRestoration: (@MainActor (Bool) -> Void)?

    func pause() { isPlaying = false; pauses += 1 }
    func setPictureInPicture(_ active: Bool) { pip = active }
    func restorePictureInPicturePresentation(completion: @escaping @MainActor (Bool) -> Void) {
        pendingRestoration = completion
    }
    func finishRestoration(_ restored: Bool) {
        let completion = pendingRestoration
        pendingRestoration = nil
        completion?(restored)
    }
}

@MainActor final class Bridge {
    var state: AutomaticPictureInPicture.State { policy.state }
    var controller: AVPictureInPictureController? = AVPictureInPictureController()
    var owner: PlaybackOwner? = PlaybackOwner()
    var policy = AutomaticPictureInPicture()
    var backgroundTask: Task<Void, Never>?
    var shutdownTask: Task<Void, Never>?
    var invalidating = false
    var invalidated = false
    var shutdownCompletions: [@MainActor () -> Void] = []
    var restorationCompletion: ((Bool) -> Void)?
    var restorationID: UUID?
    var nativeLayer: NSObject?
    var softwareSource: NSObject?

    func configure(owner: PlaybackOwner) {}
    func replaceController(_ replacement: AVPictureInPictureController?) { controller = replacement }
    // ACTUAL_METHODS
}

@main @MainActor struct Regression {
    static func main() async throws {
        var checks = 0
        func check(_ result: @autoclosure () -> Bool, _ message: String) {
            precondition(result(), message)
            checks += 1
        }
        do {
            let bridge = Bridge()
            bridge.enteredBackground()
            bridge.enteredBackground()
            check(bridge.owner?.pauses == 0, "Backgrounding must not cancel automatic entry")
            try await Task.sleep(for: .milliseconds(1150))
            check(bridge.owner?.pauses == 1, "Declined entry pauses exactly once")
        }
        do {
            let bridge = Bridge(), controller = bridge.controller!
            bridge.enteredBackground()
            bridge.pictureInPictureControllerWillStartPictureInPicture(controller)
            check(bridge.state == .starting && bridge.owner?.pip == true, "Entry pins its video source")
            try await Task.sleep(for: .milliseconds(1150))
            check(bridge.owner?.pauses == 0, "A slow native animation cannot trigger the handoff timeout")
            bridge.pictureInPictureControllerDidStartPictureInPicture(controller)
            check(bridge.state == .active, "Only didStart completes the entry transition")
            bridge.pictureInPictureControllerWillStopPictureInPicture(controller)
            check(bridge.state == .stopping && bridge.owner?.pip == true, "Exit retains video until didStop")
            bridge.pictureInPictureControllerDidStopPictureInPicture(controller)
            check(
                bridge.state == .inactive && bridge.owner?.pauses == 1,
                "Closing PiP pauses background playback")
        }
        do {
            let bridge = Bridge(), controller = bridge.controller!
            bridge.pictureInPictureControllerWillStartPictureInPicture(controller)
            bridge.pictureInPictureControllerDidStartPictureInPicture(controller)
            bridge.enteredBackground()
            check(bridge.backgroundTask == nil, "PiP can start before UIKit backgrounds")
            var completions: [Bool] = []
            bridge.pictureInPictureController(
                controller,
                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { completions.append($0) })
            check(
                completions.isEmpty && bridge.state == .restoring,
                "Restoration waits for the destination layout")
            bridge.enteredForeground()
            check(bridge.state == .restoring, "Foregrounding cannot clear a return animation in progress")
            bridge.owner?.finishRestoration(true)
            check(completions == [true], "AVKit is acknowledged after layout is ready")
            bridge.pictureInPictureControllerWillStopPictureInPicture(controller)
            check(bridge.state == .restoring, "willStop must preserve restoration intent")
            bridge.pictureInPictureControllerDidStopPictureInPicture(controller)
            check(
                bridge.state == .inactive && bridge.owner?.pauses == 0,
                "Returning to full screen preserves playback")
            check(completions == [true], "A restore request completes only once")
        }
        do {
            let bridge = Bridge(), controller = bridge.controller!
            bridge.pictureInPictureControllerWillStartPictureInPicture(controller)
            var restored: Bool?
            bridge.pictureInPictureController(
                controller,
                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored = $0 })
            bridge.owner?.finishRestoration(false)
            check(
                restored == false && bridge.state == .active,
                "An unavailable destination keeps the existing PiP session")
            bridge.pictureInPictureControllerWillStopPictureInPicture(controller)
            bridge.pictureInPictureControllerDidStopPictureInPicture(controller)
            check(
                bridge.owner?.pauses == 1,
                "A failed restoration cannot leave background audio playing after close")
        }
        do {
            let bridge = Bridge(), controller = bridge.controller!
            bridge.enteredBackground()
            bridge.pictureInPictureController(
                controller, failedToStartPictureInPictureWithError: CocoaError(.featureUnsupported))
            check(
                bridge.owner?.pauses == 1 && bridge.backgroundTask == nil,
                "Failed entry cancels its handoff timer")
        }
        do {
            let bridge = Bridge()
            bridge.controller?.isPictureInPicturePossible = false
            bridge.enteredBackground()
            check(
                bridge.owner?.pauses == 1 && bridge.backgroundTask == nil,
                "Unsupported routes pause immediately")
            let external = Bridge()
            external.owner?.externalPlaybackActive = true
            external.controller?.isPictureInPicturePossible = false
            external.enteredBackground()
            check(external.owner?.pauses == 0, "External playback remains independent")
        }
        do {
            let bridge = Bridge()
            bridge.enteredBackground()
            bridge.enteredForeground()
            try await Task.sleep(for: .milliseconds(1150))
            check(bridge.owner?.pauses == 0, "Foreground return cancels the delayed pause")
            let stale = AVPictureInPictureController()
            bridge.pictureInPictureControllerWillStartPictureInPicture(stale)
            check(bridge.state == .inactive, "A replaced controller cannot change lifecycle state")
            bridge.owner?.hasEnded = true
            bridge.enteredBackground()
            check(bridge.owner?.pauses == 1, "Ended content cannot automatically enter PiP")
        }
        do {
            let bridge = Bridge(), controller = bridge.controller!
            bridge.pictureInPictureControllerWillStartPictureInPicture(controller)
            var released = 0
            bridge.invalidate { released += 1 }
            bridge.invalidate { released += 1 }
            check(released == 0 && controller.stops == 1, "Teardown waits for the native closing animation")
            bridge.pictureInPictureControllerDidStartPictureInPicture(controller)
            check(controller.stops == 2, "Closing during entry retries stop once AVKit becomes active")
            bridge.pictureInPictureControllerDidStopPictureInPicture(controller)
            check(
                released == 2 && bridge.controller == nil, "didStop releases every queued owner exactly once")
            bridge.invalidate { released += 1 }
            check(
                released == 3 && bridge.shutdownTask == nil,
                "Repeated teardown cannot leave callbacks pending")
        }
        do {
            let bridge = Bridge(), controller = bridge.controller!
            bridge.pictureInPictureControllerWillStartPictureInPicture(controller)
            var completions: [Bool] = []
            bridge.pictureInPictureController(
                controller,
                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { completions.append($0) })
            bridge.invalidate()
            check(completions == [false], "Closing releases an outstanding restoration callback")
            bridge.owner?.finishRestoration(true)
            check(completions == [false], "A late destination callback cannot revive a closing session")
            bridge.pictureInPictureControllerDidStopPictureInPicture(controller)
        }
        do {
            var bridge: Bridge? = Bridge()
            weak let retained = bridge
            let controller = bridge!.controller!
            bridge!.pictureInPictureControllerWillStartPictureInPicture(controller)
            var released = false
            bridge!.invalidate { released = true }
            bridge = nil
            check(retained != nil, "The source bridge survives disappearance of its SwiftUI owner")
            try await Task.sleep(for: .milliseconds(2150))
            check(
                released && retained == nil,
                "A missing AVKit callback cannot leak the video engine or its bridge")
        }
        do {
            let bridge = Bridge(), controller = bridge.controller!
            bridge.pictureInPictureControllerWillStartPictureInPicture(controller)
            var previous: [Bool] = [], current: [Bool] = []
            bridge.pictureInPictureController(
                controller,
                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { previous.append($0) })
            let lateDestination = bridge.owner?.pendingRestoration
            bridge.pictureInPictureController(
                controller,
                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { current.append($0) })
            lateDestination?(true)
            check(
                previous == [false] && current.isEmpty,
                "A superseded destination cannot complete a newer restore")
            bridge.owner?.finishRestoration(true)
            check(current == [true], "The current destination completes its own restore")
            bridge.pictureInPictureControllerDidStopPictureInPicture(controller)
        }
        do {
            let bridge = Bridge(), controller = bridge.controller!
            bridge.pictureInPictureControllerWillStartPictureInPicture(controller)
            bridge.pictureInPictureControllerDidStartPictureInPicture(controller)
            controller.isPictureInPictureActive = true
            bridge.enteredForeground()
            check(bridge.state == .active, "Opening the app cannot steal video from an active PiP window")
            controller.isPictureInPictureActive = false
            bridge.enteredForeground()
            check(
                bridge.state == .inactive && bridge.owner?.pip == false,
                "A closed system window cannot leave inline controls hidden")
        }
        print("Passed \(checks) automatic PiP lifecycle regression checks.")
    }
}
