import AetherEngine
import AVFoundation
import Combine
import Observation
import UIKit
import VesperCore

@MainActor @Observable
final class AetherPlaybackController {
    private(set) var timeline = PlaybackTimeline(elapsed: 0, duration: 0, isSeekable: false)
    private(set) var isPlaying = false
    private(set) var isBuffering = true
    private(set) var hasEnded = false
    private(set) var error: String?
    private(set) var audioTracks: [PlaybackTrack] = []
    private(set) var subtitleTracks: [PlaybackTrack] = []
    private(set) var selectedAudio: Int32 = -1
    private(set) var selectedSubtitle: Int32 = -1
    private(set) var speed: Float = 1
    private(set) var isBoosting = false
    private(set) var fillsScreen = false
    private(set) var subtitleCues: [SubtitleCue] = []
    private(set) var subtitleTime: Double = 0
    let pictureInPicture = NativePictureInPicture()
    var pictureInPictureState: AutomaticPictureInPicture.State { pictureInPicture.state }
    private(set) var videoAspect: CGFloat = 16 / 9

    @ObservationIgnored private(set) var engine: AetherEngine?
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let resumeSeconds: Double
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var scrobbleReporter = TraktPlaybackReporter()
    @ObservationIgnored private let onScrobble: (@MainActor (TraktScrobbleEvent) -> Void)?
    @ObservationIgnored private let onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)?
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var nativeAudioTask: Task<Void, Never>?
    @ObservationIgnored private var nativeAudioItem: AVPlayerItem?
    @ObservationIgnored private var nativeAudioGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var nativeAudioOptions: [Int32: AVMediaSelectionOption] = [:]
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var audioSessionLease: UUID?
    private var ownsAudioSession: Bool { audioSessionLease != nil }
    @ObservationIgnored private let restorePresentation: PlaybackRestoration?
    @ObservationIgnored private var previousIdleTimer = false
    @ObservationIgnored private var wantsPlayback = true
    @ObservationIgnored private var progressReporter = PlaybackProgressReporter()

    init(
        url: URL, resumeSeconds: Double = 0, isLive: Bool = false,
        onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)? = nil,
        onScrobble: (@MainActor (TraktScrobbleEvent) -> Void)? = nil,
        restorePresentation: PlaybackRestoration? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.url = url
        self.resumeSeconds = resumeSeconds.isFinite && resumeSeconds > 0 ? resumeSeconds : 0
        self.isLive = isLive
        self.onProgress = onProgress
        self.onScrobble = onScrobble
        self.restorePresentation = restorePresentation
        self.clock = clock
    }

    isolated deinit {
        loadTask?.cancel()
        seekTask?.cancel()
        nativeAudioTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to surface: AetherPlayerView) {
        guard !stopped else { return }
        if let engine {
            engine.bind(view: surface)
            return
        }
        previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        do {
            let engine = try AetherEngine()
            self.engine = engine
            engine.backgroundPlaybackEnabled = true
            engine.ownsVideoNowPlayingSession = true
            engine.bind(view: surface)
            try activateAudio()
            engine.objectWillChange.debounce(for: .milliseconds(16), scheduler: RunLoop.main)
                .sink { [weak self] in self?.synchronize() }.store(in: &subscriptions)
            engine.clock.$currentTime.throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] _ in self?.synchronize() }.store(in: &subscriptions)
            observeAudioSession()
            load(at: resumeSeconds)
        } catch { fail("The Aether player could not start. Try again or choose an external player.") }
    }

    private func activateAudio() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .moviePlayback)
        try audio.setActive(true)
        audioSessionLease = PlaybackAudioOwnership.acquire()
    }

    private func load(at position: Double) {
        guard let engine, !stopped else { return }
        loadTask?.cancel()
        seekTask?.cancel()
        loaded = false
        hasEnded = false
        isBuffering = true
        progressReporter = PlaybackProgressReporter()
        let url = url, isLive = isLive
        loadTask = Task { [weak self] in
            do {
                try await engine.load(
                    url: url, startPosition: position > 0 ? position : nil,
                    options: LoadOptions(isLive: isLive, autoplay: false))
                try Task.checkCancellation()
                guard let self, !self.stopped else { return }
                self.loaded = true
                if self.wantsPlayback {
                    self.applyPlaybackRate()
                    engine.play()
                }
                self.synchronize()
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                self?.fail("This source could not be played. Try another source or an external player.")
            }
        }
    }

    func togglePlayback() {
        guard let engine, !stopped, error == nil else { return }
        if isPlaying {
            pause()
            return
        }
        do { if !ownsAudioSession { try activateAudio() } } catch {
            fail("Audio playback could not resume. Try another player.")
            return
        }
        wantsPlayback = true
        if hasEnded {
            load(at: 0)
            return
        }
        guard loaded else { return }
        if !engine.isSessionReady {
            load(at: timeline.elapsed)
            return
        }
        applyPlaybackRate()
        engine.play()
        synchronize()
    }

    func pause() {
        guard !stopped else { return }
        reportProgress(force: true)
        wantsPlayback = false
        isBoosting = false
        engine?.pause()
        applyPlaybackRate()
        isPlaying = false
        reportScrobble()
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
    }

    func seek(fraction: Double) {
        guard let engine, let seconds = timeline.seekTarget(fraction: fraction), !stopped, error == nil else {
            return
        }
        seekTask?.cancel()
        timeline = PlaybackTimeline(elapsed: seconds, duration: timeline.duration, isSeekable: true)
        seekTask = Task { [weak self] in
            await engine.seek(to: seconds)
            guard !Task.isCancelled else { return }
            self?.synchronize()
        }
    }

    func skip(seconds: Double) {
        guard let target = timeline.skipTarget(seconds: seconds) else { return }
        seek(fraction: target / timeline.duration)
    }

    func selectAudio(_ id: Int32) {
        guard audioTracks.contains(where: { $0.id == id }), !stopped else { return }
        if engine?.videoRoute == .remoteBypass, let item = nativeAudioItem,
            let group = nativeAudioGroup, let option = nativeAudioOptions[id]
        {
            item.select(option, in: group)
            selectedAudio = id
        } else {
            engine?.selectAudioTrack(index: Int(id))
        }
    }

    func selectSubtitle(_ id: Int32) {
        guard id == -1 || subtitleTracks.contains(where: { $0.id == id }), !stopped else { return }
        if id == -1 { engine?.clearSubtitle() } else { engine?.selectSubtitleTrack(index: Int(id)) }
        synchronize()
    }

    func setSpeed(_ value: Float) {
        guard PlaybackSpeed.values.contains(value), !stopped else { return }
        speed = value
        applyPlaybackRate()
    }

    func beginBoost() {
        guard loaded, !stopped, error == nil, wantsPlayback, isPlaying,
            !isBuffering, !hasEnded, !isBoosting
        else { return }
        isBoosting = true
        applyPlaybackRate()
    }

    func endBoost() {
        guard isBoosting else { return }
        isBoosting = false
        if !stopped, error == nil { applyPlaybackRate() }
    }

    private func applyPlaybackRate() {
        guard loaded, !stopped, !hasEnded, error == nil else { return }
        engine?.setRate(isBoosting ? PlaybackSpeed.boost : speed)
    }

    func setFill(_ fill: Bool) {
        guard !stopped else { return }
        fillsScreen = fill
        engine?.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }

    var externalPlaybackActive: Bool { engine?.currentAVPlayer?.isExternalPlaybackActive == true }

    func setPictureInPicture(_ active: Bool) { engine?.pictureInPictureActive = active }

    func enteredBackground() {
        guard !stopped else { return }
        pictureInPicture.configure(owner: self)
        pictureInPicture.enteredBackground()
    }

    func enteredForeground() { pictureInPicture.enteredForeground() }

    func restorePictureInPicturePresentation(completion: @escaping @MainActor (Bool) -> Void) {
        guard !stopped, let restorePresentation else {
            completion(false)
            return
        }
        restorePresentation(completion)
    }

    func skipFromPictureInPicture(seconds: Double) async {
        guard !stopped, error == nil else { return }
        skip(seconds: seconds)
        await seekTask?.value
    }

    func stop() {
        guard !stopped else { return }
        reportProgress(force: true)
        reportScrobble(finishing: true)
        stopped = true
        isBoosting = false
        wantsPlayback = false
        isPlaying = false
        cancelWork()
        releaseEngine()
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
    }

    private func cancelWork() {
        loadTask?.cancel()
        loadTask = nil
        seekTask?.cancel()
        seekTask = nil
        nativeAudioTask?.cancel()
        nativeAudioTask = nil
        nativeAudioItem = nil
        nativeAudioGroup = nil
        nativeAudioOptions = [:]
        subscriptions.removeAll()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func releaseEngine() {
        let engine = engine
        let lease = audioSessionLease
        self.engine = nil
        audioSessionLease = nil
        pictureInPicture.invalidate {
            engine?.stop()
            if let lease, PlaybackAudioOwnership.release(lease) {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func synchronize() {
        guard let engine, !stopped, error == nil else { return }
        if case .error = engine.state {
            fail("This source could not be played. Try another source or an external player.")
            return
        }
        hasEnded = engine.state == .ended
        let seekable = engine.canSeek || (hasEnded && timeline.isSeekable)
        timeline = PlaybackTimeline(
            elapsed: engine.isSeeking ? engine.seekTarget ?? engine.currentTime : engine.currentTime,
            duration: engine.duration, isSeekable: seekable)
        isBuffering = engine.isBuffering || (!engine.isSessionReady && !hasEnded)
        isPlaying = engine.state == .playing || (engine.state == .seeking && wantsPlayback)
        if engine.videoRoute == .remoteBypass {
            synchronizeNativeAudio(engine.currentAVPlayer?.currentItem)
        } else {
            audioTracks = engine.audioTracks.compactMap(Self.track)
            selectedAudio = engine.activeAudioTrackIndex.flatMap(Int32.init(exactly:)) ?? -1
        }
        subtitleTracks = engine.subtitleTracks.compactMap(Self.track)
        selectedSubtitle = engine.activeSubtitleTrackIndex.flatMap(Int32.init(exactly:)) ?? -1
        subtitleCues = engine.videoRoute == .remoteBypass ? [] : engine.subtitleCues
        subtitleTime = engine.sourceTime
        if engine.sourceVideoHeight > 0 {
            videoAspect =
                CGFloat(engine.sourceVideoWidth) * CGFloat(engine.sourceVideoPixelAspectRatio)
                / CGFloat(engine.sourceVideoHeight)
        }
        if hasEnded {
            wantsPlayback = false
            isBoosting = false
            applyPlaybackRate()
        }
        UIApplication.shared.isIdleTimerDisabled = isPlaying ? true : previousIdleTimer
        pictureInPicture.configure(owner: self)
        reportProgress(force: hasEnded)
        reportScrobble()
    }

    private static func track(_ value: TrackInfo) -> PlaybackTrack? {
        guard let id = Int32(exactly: value.id) else { return nil }
        return PlaybackTrack(id: id, name: value.name)
    }

    private func synchronizeNativeAudio(_ item: AVPlayerItem?) {
        guard let item else { return }
        if item === nativeAudioItem {
            if let group = nativeAudioGroup,
                let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            {
                selectedAudio = nativeAudioOptions.first { $0.value == selected }?.key ?? -1
            }
            return
        }
        nativeAudioTask?.cancel()
        nativeAudioItem = item
        nativeAudioGroup = nil
        nativeAudioOptions = [:]
        audioTracks = []
        selectedAudio = -1
        nativeAudioTask = Task { [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), !Task.isCancelled,
                let self, !self.stopped, self.nativeAudioItem === item,
                self.engine?.videoRoute == .remoteBypass, self.engine?.currentAVPlayer?.currentItem === item
            else { return }
            self.nativeAudioGroup = group
            self.audioTracks = group.options.enumerated().compactMap { index, option in
                guard let id = Int32(exactly: index) else { return nil }
                self.nativeAudioOptions[id] = option
                return PlaybackTrack(id: id, name: option.displayName)
            }
            self.synchronize()
        }
    }

    private func reportProgress(force: Bool) {
        guard let onProgress, let engine, loaded, !stopped, !engine.isSeeking, !engine.isLive,
            timeline.isSeekable, timeline.duration > 0, timeline.elapsed >= 5 || hasEnded
        else { return }
        if let update = progressReporter.checkpoint(
            timeline: timeline, ended: hasEnded, force: force, now: clock())
        {
            onProgress(update)
        }
    }

    private func reportScrobble(finishing: Bool = false) {
        guard let onScrobble, !stopped, !isLive else { return }
        if loaded, engine?.isSeeking != true, timeline.duration > 0 {
            let sample = TraktPlaybackSample(
                elapsed: timeline.elapsed, duration: timeline.duration,
                playing: isPlaying, buffering: isBuffering, ended: hasEnded)
            if let event = scrobbleReporter.update(sample) { onScrobble(event) }
        }
        // Closing during a seek still ends the previous valid watching session.
        if finishing, let event = scrobbleReporter.finish() { onScrobble(event) }
    }

    private func fail(_ message: String) {
        guard !stopped, error == nil else { return }
        reportProgress(force: true)
        reportScrobble(finishing: true)
        error = message
        isPlaying = false
        isBuffering = false
        isBoosting = false
        wantsPlayback = false
        cancelWork()
        releaseEngine()
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    if let lease = self.audioSessionLease { _ = PlaybackAudioOwnership.release(lease) }
                    self.audioSessionLease = nil
                    self.pause()
                }
            })
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
                [weak self] notification in
                if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                    == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                {
                    Task { @MainActor in self?.pause() }
                }
            })
    }
}
