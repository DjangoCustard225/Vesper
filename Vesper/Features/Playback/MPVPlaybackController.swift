import AVFAudio
import Observation
import QuartzCore
import UIKit
import VesperCore

@MainActor @Observable
final class MPVPlaybackController {
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

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var session: MPVSession?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var openingTimeout: Task<Void, Never>?
    @ObservationIgnored private var ownsAudioSession = false
    @ObservationIgnored private var previousIdleTimer = false
    @ObservationIgnored private var wantsPlayback = false
    @ObservationIgnored private var requestedRate: Float = 1
    @ObservationIgnored private var pendingResume: Double?
    @ObservationIgnored private var awaitingResume: Double?
    @ObservationIgnored private var scrobbleReporter = TraktPlaybackReporter()
    @ObservationIgnored private let onScrobble: (@MainActor (TraktScrobbleEvent) -> Void)?
    @ObservationIgnored private let onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)?
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var progressReporter = PlaybackProgressReporter()

    init(
        url: URL, resumeSeconds: Double = 0, isLive: Bool = false,
        onProgress: (@MainActor (PlaybackProgressUpdate) -> Void)? = nil,
        onScrobble: (@MainActor (TraktScrobbleEvent) -> Void)? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.url = url
        self.isLive = isLive
        self.pendingResume = resumeSeconds.isFinite && resumeSeconds > 0 ? resumeSeconds : nil
        self.onProgress = onProgress
        self.onScrobble = onScrobble
        self.clock = clock
    }

    isolated deinit {
        session?.stop()
        openingTimeout?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to layer: CAMetalLayer) {
        guard !started, !stopped else { return }
        started = true
        previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback)
            try audio.setActive(true)
            ownsAudioSession = true
        } catch {
            fail("Audio playback could not start. Try again or choose an external player.")
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        observeAudioSession()
        let session = MPVSession(layer: layer) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.error == nil else { return }
                switch event {
                case .state(let state): self.update(state)
                case .failure(let message): self.fail(message)
                }
            }
        }
        self.session = session
        wantsPlayback = true
        isPlaying = true
        session.start(url: url)
        applyPlaybackRate()
        if fillsScreen { session.fill(true) }
        openingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, !self.stopped, !self.loaded else { return }
            self.fail("This source is taking too long to open. Try another source or an external player.")
        }
    }

    func togglePlayback() {
        guard started, !stopped, error == nil else { return }
        if isPlaying {
            pause()
        } else {
            do {
                if !ownsAudioSession {
                    try AVAudioSession.sharedInstance().setActive(true)
                    ownsAudioSession = true
                }
            } catch {
                fail("Audio playback could not resume. Try again or choose an external player.")
                return
            }
            if hasEnded {
                session?.seek(0)
                hasEnded = false
                timeline = PlaybackTimeline(
                    elapsed: 0, duration: timeline.duration, isSeekable: timeline.isSeekable)
            }
            wantsPlayback = true
            applyPlaybackRate()
            session?.pause(false)
            isPlaying = true
            reportScrobble()
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    func pause() {
        guard started, !stopped else { return }
        reportProgress(force: true)
        wantsPlayback = false
        session?.pause(true)
        isBoosting = false
        applyPlaybackRate()
        isPlaying = false
        reportScrobble()
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
    }

    func seek(fraction: Double) {
        guard let seconds = timeline.seekTarget(fraction: fraction), !stopped, error == nil else { return }
        pendingResume = nil
        awaitingResume = nil
        session?.seek(seconds)
        timeline = PlaybackTimeline(
            elapsed: seconds, duration: timeline.duration, isSeekable: timeline.isSeekable)
    }

    func skip(seconds: Double) {
        guard let target = timeline.skipTarget(seconds: seconds) else { return }
        seek(fraction: target / timeline.duration)
    }

    func selectAudio(_ id: Int32) {
        guard audioTracks.contains(where: { $0.id == id }), !stopped else { return }
        session?.select(track: id, subtitle: false)
        selectedAudio = id
    }

    func selectSubtitle(_ id: Int32) {
        guard id == -1 || subtitleTracks.contains(where: { $0.id == id }), !stopped else { return }
        session?.select(track: id, subtitle: true)
        selectedSubtitle = id
    }

    func setSpeed(_ value: Float) {
        guard PlaybackSpeed.values.contains(value), !stopped else { return }
        speed = value
        applyPlaybackRate()
    }

    func beginBoost() {
        guard started, loaded, !stopped, error == nil, wantsPlayback, isPlaying,
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
        guard session != nil else { return }
        let desired = isBoosting ? PlaybackSpeed.boost : speed
        guard requestedRate != desired else { return }
        requestedRate = desired
        session?.rate(desired)
    }

    func setFill(_ fill: Bool) {
        fillsScreen = fill
        guard !stopped else { return }
        session?.fill(fill)
    }

    func stop() {
        guard !stopped else { return }
        reportProgress(force: true)
        reportScrobble(finishing: true)
        stopped = true
        isBoosting = false
        wantsPlayback = false
        isPlaying = false
        openingTimeout?.cancel()
        openingTimeout = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        session?.stop()
        session = nil
        if started { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        if ownsAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsAudioSession = false
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped else { return }
                    self.ownsAudioSession = false
                    self.pause()
                }
            })
        observers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) {
                [weak self] notification in
                let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if value == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    Task { @MainActor [weak self] in self?.pause() }
                }
            })
        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pause()
                    self?.session?.suspendVideo(true)
                }
            })
        observers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.session?.suspendVideo(false) }
            })
    }

    private func update(_ state: MPVSnapshot) {
        loaded = state.loaded
        timeline = PlaybackTimeline(
            elapsed: state.elapsed, duration: state.duration, isSeekable: state.seekable)
        isBuffering = state.buffering && !state.ended
        audioTracks = state.audio
        subtitleTracks = state.subtitles
        selectedAudio = state.selectedAudio
        selectedSubtitle = state.selectedSubtitle
        if state.loaded {
            openingTimeout?.cancel()
            openingTimeout = nil
        }
        if state.ended {
            wantsPlayback = false
            isBoosting = false
            applyPlaybackRate()
        }
        hasEnded = state.ended
        isPlaying = wantsPlayback && !hasEnded
        UIApplication.shared.isIdleTimerDisabled = isPlaying ? true : previousIdleTimer
        if let position = pendingResume, loaded, timeline.isSeekable, timeline.duration > 0 {
            pendingResume = nil
            if position / timeline.duration < 0.95 {
                awaitingResume = position
                session?.seek(position)
                return
            }
        }
        if let position = awaitingResume {
            // Do not overwrite saved progress with the opening frame while the seek is pending.
            guard abs(timeline.elapsed - position) < 3 else { return }
            awaitingResume = nil
        }
        reportProgress(force: state.ended)
        reportScrobble()
    }

    private func reportProgress(force: Bool) {
        guard let onProgress, loaded, !stopped, pendingResume == nil, awaitingResume == nil,
            timeline.isSeekable, timeline.duration > 0,
            timeline.elapsed >= 5 || hasEnded
        else { return }
        if let update = progressReporter.checkpoint(
            timeline: timeline, ended: hasEnded, force: force, now: clock())
        {
            onProgress(update)
        }
    }

    private func reportScrobble(finishing: Bool = false) {
        guard let onScrobble, !stopped, !isLive else { return }
        if loaded, pendingResume == nil, awaitingResume == nil, timeline.duration > 0 {
            let sample = TraktPlaybackSample(
                elapsed: timeline.elapsed, duration: timeline.duration,
                playing: isPlaying, buffering: isBuffering, ended: hasEnded)
            if let event = scrobbleReporter.update(sample) { onScrobble(event) }
        }
        // Closing during a seek still ends the previous valid watching session.
        if finishing, let event = scrobbleReporter.finish() { onScrobble(event) }
    }

    private func fail(_ message: String) {
        reportProgress(force: true)
        reportScrobble(finishing: true)
        isBoosting = false
        wantsPlayback = false
        error = message
        isBuffering = false
        isPlaying = false
        openingTimeout?.cancel()
        openingTimeout = nil
        session?.stop()
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
    }
}
