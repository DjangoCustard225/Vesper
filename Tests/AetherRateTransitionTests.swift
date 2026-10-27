import Foundation

private struct Time {
    let seconds: Double
    static let invalid = Time(seconds: .nan)
}

private final class Player {
    enum TimeControlStatus { case paused, playing, waitingToPlayAtSpecifiedRate }
    final class Item {
        enum Status { case unknown, readyToPlay, failed }
        var status = Status.readyToPlay
    }
    var currentItem: Item? = Item()
    var timeControlStatus = TimeControlStatus.playing
    var commands: [String] = []
    private var storedRate: Float = 1
    var rate: Float {
        get { storedRate }
        set {
            storedRate = newValue
            commands.append("rate:\(newValue)")
        }
    }
    var defaultRate: Float = 1
    func playImmediately(atRate value: Float) {
        storedRate = value
        commands.append("immediate:\(value)")
    }
}

private final class NativeHost {
    let avPlayer = Player()
    var playIntent = true
    func setRate(_ value: Float) {
        playIntent = value != 0
        // INSERT_NATIVE_RATE_BODY
    }
}

private final class Synchronizer {
    var rate: Float = 1
    var seconds: Double = 10
    var writes = 0
    var timeResets = 0
    func currentTime() -> Time { Time(seconds: seconds) }
    func setRate(_ value: Float, time: Time) {
        writes += 1
        rate = value
        if time.seconds.isFinite {
            seconds = time.seconds
            timeResets += 1
        }
    }
}

private struct Timeline {
    func sourceSeconds(forRenderer value: Double) -> Double { value }
}

private enum EngineLog {
    enum Category { case swPlayback }
    static func emit(_ message: String, category: Category) {}
}

private final class AudioOutput {
    let synchronizer = Synchronizer()
    let timeline = Timeline()
    // INSERT_SOFTWARE_RATE_METHOD
}

@main private struct RateRegression {
    static func main() {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            passed += 1
        }
        let host = NativeHost()
        host.setRate(2)
        check(
            host.avPlayer.commands == ["immediate:2.0"],
            "Buffered native playback must change speed in one immediate command")
        check(
            host.avPlayer.defaultRate == 2 && host.playIntent,
            "Boost must persist across internal player resumes")
        host.setRate(2)
        check(host.avPlayer.commands.count == 1, "Identical running rates must not disturb playback")
        host.setRate(1.5)
        check(
            host.avPlayer.commands.last == "immediate:1.5" && host.avPlayer.defaultRate == 1.5,
            "Release must immediately restore the selected speed")
        host.setRate(0)
        check(
            host.avPlayer.commands.last == "rate:0.0" && !host.playIntent && host.avPlayer.defaultRate == 1.5,
            "Zero must stop playback without losing the resume speed")
        for state in [Player.TimeControlStatus.paused, .waitingToPlayAtSpecifiedRate] {
            let host = NativeHost()
            host.avPlayer.timeControlStatus = state
            host.setRate(1.25)
            check(
                host.avPlayer.commands == ["rate:1.25"],
                "Startup and starvation must retain AVPlayer's normal buffering policy")
        }
        for status in [Player.Item.Status.unknown, .failed] {
            let host = NativeHost()
            host.avPlayer.currentItem?.status = status
            host.setRate(2)
            check(host.avPlayer.commands == ["rate:2.0"], "Unready items must not enter immediate playback")
        }
        let missing = NativeHost()
        missing.avPlayer.currentItem = nil
        missing.setRate(2)
        check(missing.avPlayer.commands == ["rate:2.0"], "A missing item must not enter immediate playback")
        let audio = AudioOutput()
        audio.setRate(2)
        audio.synchronizer.seconds = 11.25
        audio.setRate(1.5)
        check(
            audio.synchronizer.seconds == 11.25 && audio.synchronizer.timeResets == 0,
            "Hold and release must preserve the advancing shared clock")
        audio.setRate(1.5)
        check(audio.synchronizer.writes == 2, "Repeated software rates must not resubmit clock changes")
        audio.synchronizer.rate = 0
        audio.setRate(1.5)
        check(
            audio.synchronizer.rate == 1.5 && audio.synchronizer.writes == 3,
            "Resume after a pause or interruption must still issue a rate change")
        print("Passed \(passed) Aether native/software rate regression checks.")
    }
}
