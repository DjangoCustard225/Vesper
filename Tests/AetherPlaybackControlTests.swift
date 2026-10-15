import Foundation

@MainActor final class UIApplication {
    static let shared = UIApplication()
    var isIdleTimerDisabled = false
}

@MainActor final class EngineDouble {
    var isSessionReady = true
    var isSeeking = false
    var isLive = false
    var plays = 0
    var pauses = 0
    var rates: [Float] = []

    func play() { plays += 1 }

    func pause() { pauses += 1 }

    func setRate(_ value: Float) { rates.append(value) }
}

@MainActor final class ControllerProbe {
    var engine: EngineDouble? = EngineDouble()
    var isPlaying = false
    var stopped = false
    var loaded = true
    var error: String?
    var isBuffering = false
    var hasEnded = false
    var isBoosting = false
    var wantsPlayback = true
    var ownsAudioSession = false
    var previousIdleTimer = false
    var speed: Float = 1
    var timeline = PlaybackTimeline(elapsed: 120, duration: 1000, isSeekable: true)
    var now: TimeInterval = 0

    var clock: () -> TimeInterval { { self.now } }
    var progressReporter = PlaybackProgressReporter()
    var updates: [PlaybackProgressUpdate] = []
    var loads: [Double] = []
    var onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)?

    init() { onProgress = { [weak self] in self?.updates.append($0) } }

    func activateAudio() throws { ownsAudioSession = true }

    func load(at position: Double) { loads.append(position) }

    func synchronize() {}

    func fail(_ message: String) { error = message }

    func checkpoint(force: Bool = false) { reportProgress(force: force) }
    // INSERT_ACTUAL_METHODS
}

@main @MainActor struct Regression {
    static func main() {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            passed += 1
        }
        do {
            let controller = ControllerProbe()
            controller.engine!.isSessionReady = false
            controller.togglePlayback()
            check(
                controller.loads == [120] && controller.engine!.plays == 0,
                "Background resume must reopen at the last position")
        }
        do {
            let controller = ControllerProbe()
            controller.hasEnded = true
            controller.togglePlayback()
            check(controller.loads == [0], "Replay must start a fresh load at zero")
        }
        do {
            let controller = ControllerProbe()
            controller.beginBoost()
            check(
                !controller.isBoosting && controller.engine!.rates.isEmpty, "Paused playback must not boost")
            controller.isPlaying = true
            controller.setSpeed(1.5)
            controller.beginBoost()
            check(controller.isBoosting && controller.engine!.rates.last == 2, "Hold must request 2x")
            controller.endBoost()
            check(
                !controller.isBoosting && controller.engine!.rates.last == 1.5,
                "Release must restore the selected speed")
            controller.beginBoost()
            controller.pause()
            check(
                !controller.isBoosting && !controller.isPlaying && controller.engine!.pauses == 1,
                "Pause must clear boost and pause the engine")
        }
        do {
            let controller = ControllerProbe()
            controller.hasEnded = true
            controller.setSpeed(1.5)
            check(controller.engine!.rates.isEmpty, "Changing speed after EOF must not restart AVPlayer")
        }
        do {
            let controller = ControllerProbe()
            controller.checkpoint()
            controller.timeline = PlaybackTimeline(elapsed: 121, duration: 1000, isSeekable: true)
            controller.now = 1
            controller.checkpoint()
            check(controller.updates.count == 1, "Periodic progress must be throttled")
            controller.now = 15
            controller.checkpoint()
            check(
                controller.updates.count == 2 && controller.updates.last!.elapsed == 121,
                "The next checkpoint must save at 15 seconds")
            controller.timeline = PlaybackTimeline(elapsed: 950, duration: 1000, isSeekable: true)
            controller.now = 16
            controller.checkpoint()
            check(controller.updates.count == 3, "Completion threshold must save immediately")
        }
        do {
            let controller = ControllerProbe()
            controller.engine!.isSeeking = true
            controller.checkpoint(force: true)
            controller.engine!.isSeeking = false
            controller.engine!.isLive = true

            controller.checkpoint(force: true)
            check(controller.updates.isEmpty, "Seeks and live streams must not overwrite VOD progress")
        }
        do {
            let controller = ControllerProbe()
            controller.stopped = true
            controller.togglePlayback()
            check(controller.engine!.plays == 0, "A dismissed player must not resume")
        }
        print("Passed \(passed) Aether adapter transport regression checks.")
    }
}
