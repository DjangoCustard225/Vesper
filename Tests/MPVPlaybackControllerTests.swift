@main struct MPVPlaybackControllerTests {
    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    @MainActor private static func fresh() -> (MPVPlaybackController, MPVSession) {
        let controller = MPVPlaybackController(url: URL(string: "https://example.invalid/video.mkv")!)
        controller.attach(to: CAMetalLayer())
        return (controller, MPVSession.latest)
    }

    @MainActor private static func loaded() -> MPVSnapshot {
        MPVSnapshot(
            elapsed: 10, duration: 100, seekable: true, loaded: true, buffering: false,
            audio: [PlaybackTrack(id: 1, name: "English")],
            subtitles: [PlaybackTrack(id: 2, name: "English")], selectedAudio: 1)
    }

    @MainActor private static func settle() async { for _ in 0..<30 { await Task.yield() } }

    @MainActor static func main() async {
        var passed = 0

        do {
            let (c, engine) = fresh()
            c.attach(to: CAMetalLayer())
            c.beginBoost()
            expect(
                engine.operations == ["start"] && !c.isBoosting,
                "Attach must be idempotent; opening must not boost")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.beginBoost()
            c.beginBoost()
            c.endBoost()
            c.endBoost()
            expect(engine.rates == [2, 1], "Hold and release must send exactly one rate each")
            expect(
                engine.operations == ["start", "rate:2.0", "rate:1.0"],
                "Boost must never pause, seek or reload")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.setSpeed(1.5)
            c.beginBoost()
            c.setSpeed(0.75)
            c.endBoost()
            expect(engine.rates == [1.5, 2, 0.75], "Release must restore the user's latest selected speed")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.setSpeed(2)
            c.beginBoost()
            c.endBoost()
            c.setSpeed(2)
            expect(engine.rates == [2], "Holding at 2× must not reset the audio clock")
            c.setSpeed(.nan)
            c.setSpeed(20)
            expect(c.speed == 2, "Reject invalid rates")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.beginBoost()
            c.pause()
            c.endBoost()
            expect(!c.isBoosting && !c.isPlaying, "Pause must end boost")
            expect(engine.operations.suffix(2) == ["pause:true", "rate:1.0"], "Restore rate after pausing")
            c.togglePlayback()
            expect(
                engine.rates == [2, 1] && engine.operations.last == "pause:false",
                "Resume should not reset rate again")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.pause()
            engine.emit(loaded())
            await settle()
            c.beginBoost()
            expect(!c.isPlaying && engine.rates.isEmpty, "Late load/state notifications must not undo pause")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            var state = loaded()
            state.buffering = true
            engine.emit(state)
            await settle()
            c.beginBoost()
            expect(!c.isBoosting && engine.rates.isEmpty, "Do not boost while buffering")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.seek(fraction: 2)
            c.skip(seconds: -1000)
            c.seek(fraction: .nan)
            expect(engine.seeks == [100, 0], "Seeks must clamp and reject non-finite input")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.selectAudio(99)
            c.selectAudio(1)
            c.selectSubtitle(2)
            c.selectSubtitle(-1)
            expect(
                Array(engine.operations.suffix(3)) == ["aid:1", "sid:2", "sid:-1"],
                "Select only valid tracks, including subtitles off")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.setFill(true)
            c.setFill(false)
            expect(
                !c.fillsScreen && Array(engine.operations.suffix(2)) == ["fill:true", "fill:false"],
                "The Fit video / Fill screen menu must remain available")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.beginBoost()
            var state = loaded()
            state.ended = true
            engine.emit(state)
            await settle()
            expect(
                c.hasEnded && !c.isBoosting && !c.isPlaying && engine.rates == [2, 1],
                "EOF must end boost and restore speed")
            c.togglePlayback()
            expect(
                !c.hasEnded && c.isPlaying && engine.seeks == [0] && engine.operations.last == "pause:false",
                "Replay must rewind before resuming")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.beginBoost()
            engine.fail()
            await settle()
            expect(
                c.error != nil && !c.isPlaying && !c.isBoosting && engine.operations.last == "stop",
                "Engine failure must stop playback")
            engine.emit(loaded())
            await settle()
            expect(c.error != nil && !c.isPlaying, "Late snapshots must not revive a failed source")
            c.stop()
            passed += 1
        }
        do {
            let (c, engine) = fresh()
            engine.emit(loaded())
            await settle()
            c.stop()
            c.stop()
            let count = engine.operations.count
            c.togglePlayback()
            c.seek(fraction: 0.5)
            c.beginBoost()
            engine.emit(loaded())
            await settle()
            expect(
                engine.operations.count == count && !c.isPlaying,
                "Stop must be idempotent and ignore late input/events")
            expect(!UIApplication.shared.isIdleTimerDisabled, "Closing must restore the idle timer")
            passed += 1
        }
        await testPeriodicProgress()
        passed += 1
        await testResumeDoesNotOverwriteSavedPosition()
        passed += 1
        await testShorterSource()
        passed += 1
        await testCompletionProgress()
        passed += 1
        await testBackgroundProgress()
        passed += 1
        print("Passed \(passed) mpv playback controller regression tests.")
    }

    @MainActor private static func testPeriodicProgress() async {
        var now: TimeInterval = 0
        var updates: [PlaybackProgressUpdate] = []
        let c = MPVPlaybackController(
            url: URL(string: "https://example.invalid/video.mkv")!,
            onProgress: { updates.append($0) }, clock: { now })
        c.attach(to: CAMetalLayer())
        let engine = MPVSession.latest!
        var state = loaded()
        engine.emit(state)
        await settle()
        expect(updates.count == 1, "Save valid initial progress")
        now = 10
        state.elapsed = 20
        engine.emit(state)
        await settle()
        expect(updates.count == 1, "Do not write progress on every engine tick")
        now = 15
        state.elapsed = 25
        engine.emit(state)
        await settle()
        expect(updates.last?.elapsed == 25 && updates.count == 2, "Save periodically while playing")
        now = 16
        state.elapsed = 26
        engine.emit(state)
        await settle()
        c.pause()
        expect(updates.last?.elapsed == 26 && updates.count == 3, "Pause must flush the latest position")
        c.togglePlayback()
        state.elapsed = 27
        engine.emit(state)
        await settle()
        c.stop()
        c.stop()
        expect(
            updates.last?.elapsed == 27 && updates.count == 4,
            "Closing saves once, including between periodic writes")

    }

    @MainActor private static func testResumeDoesNotOverwriteSavedPosition() async {
        var updates: [PlaybackProgressUpdate] = []
        let c = MPVPlaybackController(
            url: URL(string: "https://example.invalid/video.mkv")!, resumeSeconds: 40,
            onProgress: { updates.append($0) })
        c.attach(to: CAMetalLayer())
        let engine = MPVSession.latest!
        engine.emit(MPVSnapshot())
        await settle()
        expect(engine.seeks.isEmpty && updates.isEmpty, "Wait for a loaded, seekable source before resuming")
        var state = loaded()
        state.elapsed = 0
        engine.emit(state)
        await settle()
        expect(
            engine.seeks == [40] && updates.isEmpty, "Resume exactly once and suppress the opening position")
        c.pause()
        engine.emit(state)
        await settle()
        expect(
            engine.seeks == [40] && updates.isEmpty,
            "Pause and stale snapshots cannot overwrite a pending resume")
        state.elapsed = 40
        engine.emit(state)
        await settle()
        expect(updates.last?.elapsed == 40, "Record progress once the resume seek arrives")
        c.seek(fraction: 0.2)
        state.elapsed = 20
        engine.emit(state)
        await settle()
        c.stop()
        expect(
            engine.seeks == [40, 20] && updates.last?.elapsed == 20,
            "User seeks must not be undone by auto-resume")

    }

    @MainActor private static func testShorterSource() async {
        var updates: [PlaybackProgressUpdate] = []
        let c = MPVPlaybackController(
            url: URL(string: "https://example.invalid/video.mkv")!, resumeSeconds: 400,
            onProgress: { updates.append($0) })
        c.attach(to: CAMetalLayer())
        let engine = MPVSession.latest!
        engine.emit(loaded())
        await settle()
        expect(
            engine.seeks.isEmpty && updates.last?.elapsed == 10,
            "A shorter replacement source must not seek past its end")
        c.stop()

    }

    @MainActor private static func testCompletionProgress() async {
        var updates: [PlaybackProgressUpdate] = []
        let c = MPVPlaybackController(
            url: URL(string: "https://example.invalid/video.mkv")!,
            onProgress: { updates.append($0) }, clock: { 0 })
        c.attach(to: CAMetalLayer())
        let engine = MPVSession.latest!
        var state = loaded()
        engine.emit(state)
        await settle()
        state.elapsed = 95
        engine.emit(state)
        await settle()
        expect(updates.last?.elapsed == 95 && updates.count == 2, "Near-end completion must save immediately")
        state.ended = true
        engine.emit(state)
        await settle()
        expect(updates.last?.ended == true, "Actual EOF must be persisted")
        c.stop()
        expect(updates.count == 3, "Closing at EOF must not duplicate the final write")

    }

    @MainActor private static func testBackgroundProgress() async {
        var updates: [PlaybackProgressUpdate] = []
        let c = MPVPlaybackController(
            url: URL(string: "https://example.invalid/video.mkv")!,
            onProgress: { updates.append($0) }, clock: { 0 })
        c.attach(to: CAMetalLayer())
        let engine = MPVSession.latest!
        var state = loaded()
        state.seekable = false
        engine.emit(state)
        await settle()
        c.pause()
        expect(updates.isEmpty, "Live/nonseekable playback must not record progress")
        state = loaded()
        engine.emit(state)
        await settle()
        state.elapsed = 33
        engine.emit(state)
        await settle()
        await Task.detached {
            await NotificationCenter.default.post(
                name: UIApplication.didEnterBackgroundNotification, object: nil)
        }.value
        await settle()
        expect(
            updates.last?.elapsed == 33 && !c.isPlaying, "Backgrounding must save progress before suspension")
        c.stop()

    }
}
