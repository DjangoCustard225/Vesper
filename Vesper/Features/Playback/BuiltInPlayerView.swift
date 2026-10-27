import SwiftUI
import UIKit
import VesperCore

struct BuiltInPlayerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    let request: PlaybackRequest
    let gesturePreferences: PlayerGesturePreferences
    var players: [VideoPlayer]
    let closePlayer: () -> Void
    let choosePlayer: (VideoPlayer) -> Void
    @State private var controller: AetherPlaybackController
    @State private var controlsVisible = true
    @State private var applicationActive = UIApplication.shared.applicationState == .active
    @State private var scrubbing = false
    @State private var scrubFraction: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @State private var showingOptions = false
    @State private var interactionID = 0
    @State private var controlFrames: [CGRect] = []
    @State private var adjustments = PlayerSystemAdjustments()
    @State private var nextEpisode: Episode?
    @State private var intro = IntroSkipController()
    private var introLookupID: String { request.id.uuidString + ":" + String(request.introSkippingEnabled()) }

    private var introTarget: Double? {
        guard request.introSkippingEnabled(), !request.isLive, applicationActive,
            controller.pictureInPictureState == .inactive,
            !scrubbing, !showingOptions, controller.error == nil, !controller.hasEnded
        else { return nil }
        return intro.segment?.seekFraction(in: controller.timeline)
    }

    private var offersNextEpisode: Bool {
        nextEpisode != nil && request.onNextEpisode != nil && !request.isLive
            && UpNext.shouldOffer(timeline: controller.timeline, ended: controller.hasEnded)
    }

    init(
        request: PlaybackRequest, gesturePreferences: PlayerGesturePreferences, players: [VideoPlayer],
        closePlayer: @escaping () -> Void, choosePlayer: @escaping (VideoPlayer) -> Void,
        restorePresentation: @escaping PlaybackRestoration
    ) {
        self.request = request
        self.gesturePreferences = gesturePreferences
        self.players = players
        self.closePlayer = closePlayer
        self.choosePlayer = choosePlayer
        _controller = State(
            initialValue: AetherPlaybackController(
                url: request.url, resumeSeconds: request.resumeSeconds, isLive: request.isLive,
                onProgress: request.onProgress, onScrobble: request.onScrobble,
                restorePresentation: restorePresentation))
    }

    var body: some View {
        GeometryReader { geometry in
            let videoSize = CGSize(
                width: geometry.size.width + geometry.safeAreaInsets.leading
                    + geometry.safeAreaInsets.trailing,
                height: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom)
            let videoCenter = CGPoint(
                x: videoSize.width / 2 - geometry.safeAreaInsets.leading,
                y: videoSize.height / 2 - geometry.safeAreaInsets.top)
            gestureSurface(playerCanvas(size: geometry.size, videoCenter: videoCenter))
                .accessibilityAction(named: "Show or hide playback controls") { toggleControls() }
                .onPreferenceChange(PlaybackControlFrames.self) { controlFrames = $0 }
                .onChange(of: videoSize) { _, _ in controller.endBoost() }
        }
        .foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
        .statusBarHidden().persistentSystemOverlays(.hidden)
        .onChange(of: controller.isPlaying) { _, _ in scheduleHide() }
        .onChange(of: controller.isBuffering) { _, _ in scheduleHide() }
        .onChange(of: controller.isBoosting) { _, _ in scheduleHide() }
        .onChange(of: controller.pictureInPictureState) { _, state in
            if state != .inactive { hideControls() } else if applicationActive { revealControls() }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: controller.isBoosting) {
            wasBoosting, isBoosting in
            !wasBoosting && isBoosting
        }
        .onChange(of: controller.hasEnded) { _, ended in if ended { revealControls() } }
        .onChange(of: offersNextEpisode) { _, offered in if offered { revealControls() } }
        .task(id: request.id) {
            guard !request.isLive, let load = request.loadUpNext else { return }
            do {
                let next = try await load()
                guard !Task.isCancelled else { return }
                nextEpisode = next
            } catch {
                // Episode discovery is optional and must never interrupt current playback.
            }
        }
        .task(id: introLookupID) {
            guard request.introSkippingEnabled(), !request.isLive else { intro.cancel(); return }
            await intro.load(request.loadIntroSegment)
        }
        .onChange(of: controller.error) { _, error in if error != nil { adjustments.restoreBrightness() } }
        .onAppear {
            applicationActive = UIApplication.shared.applicationState == .active
            if applicationActive { revealControls() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) {
            _ in
            applicationActive = false
            prepareForBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) {
            _ in
            applicationActive = false
            prepareForBackground()
            controller.enteredBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) {
            _ in
            applicationActive = true
            controller.enteredForeground()
            revealControls()
        }
        .onChange(of: voiceOver) { _, _ in scheduleHide() }
        .onDisappear {
            intro.cancel()
            hideTask?.cancel()
            controller.stop()
            adjustments.restoreBrightness()
        }
    }

    private func prepareForBackground() {
        controller.endBoost()
        if scrubbing {
            controller.seek(fraction: scrubFraction)
            scrubbing = false
        }
        hideControls()
    }

    private func hideControls() {
        hideTask?.cancel()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { controlsVisible = false }
    }

    private func playerCanvas(size: CGSize, videoCenter: CGPoint) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // Keep the system volume slider mounted at a usable size behind the video.
            SystemVolumeAttachment(adjustments: adjustments)
                .frame(width: 160, height: 20)
                .allowsHitTesting(false).accessibilityHidden(true)
            adjustmentCapture.frame(width: 1, height: 1)
                .allowsHitTesting(false).accessibilityHidden(true)
            holdCapture.frame(width: 1, height: 1)
                .allowsHitTesting(false).accessibilityHidden(true)
            AetherVideoSurface(controller: controller).ignoresSafeArea()
                .allowsHitTesting(false).accessibilityHidden(true)
            if controlsVisible, controller.error == nil {
                Color.black.opacity(0.2).ignoresSafeArea().allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let error = controller.error {
                failure(error).padding(24).playbackControl()
            } else if controlsVisible {
                controls(size: size, videoCenter: videoCenter).transition(.opacity)
            }
            if introTarget != nil {
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            guard let target = introTarget else { return }
                            controller.endBoost()
                            controller.seek(fraction: target)
                            revealControls()
                        } label: {
                            Label("Skip Intro", systemImage: "forward.end.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).padding(.vertical, 12)
                        }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: .capsule)
                            .playbackControl()
                        Spacer()
                    }
                }.padding(.horizontal, 24).padding(.bottom, 76)
            }
            if controller.isBoosting {
                VStack {
                    Text("2×").font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                    Spacer()
                }.padding(.top, 72).allowsHitTesting(false)
            }
        }
    }

    private func gestureSurface<Content: View>(_ content: Content) -> some View {
        content.contentShape(Rectangle())
            .onTapGesture { toggleControls() }
    }

    private var holdCapture: PlayerHoldCapture {
        PlayerHoldCapture(
            enabled: gesturePreferences.holdFor2x && controller.error == nil
                && !scrubbing && !showingOptions && applicationActive
                && controller.pictureInPictureState == .inactive,
            excludedFrames: controlFrames
        ) { held in
            if held, !scrubbing, !showingOptions,
                UIApplication.shared.applicationState == .active
            {
                controller.beginBoost()
            } else {
                controller.endBoost()
            }
        }
    }

    private var adjustmentCapture: PlayerAdjustmentCapture {
        PlayerAdjustmentCapture(
            brightnessEnabled: gesturePreferences.brightnessSwipe && controller.error == nil
                && !controller.isBoosting,
            volumeEnabled: gesturePreferences.volumeSwipe && controller.error == nil
                && !controller.isBoosting,
            began: { side in
                guard !controller.isBoosting else { return }
                adjustments.begin(side)
                hideTask?.cancel()
            },
            changed: { side, fraction in
                guard !controller.isBoosting else { return }
                adjustments.adjust(side, fraction: fraction)
            }, ended: { scheduleHide() })
    }

    private func controls(size: CGSize, videoCenter: CGPoint) -> some View {
        let horizontalInset: CGFloat = size.width > size.height ? 10 : 16
        let transportSpacing = min(68, max(16, (size.width - horizontalInset * 2 - 220) / 2))
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    glassButton("Close", symbol: "xmark") { close() }.playbackControl()
                    VStack(spacing: 3) {
                        Text(request.title).font(.headline).lineLimit(1)
                        if let subtitle = request.subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(
                                1)
                        }
                    }.shadow(color: .black.opacity(0.6), radius: 8).frame(maxWidth: .infinity).padding(
                        .top, 6)
                    Color.clear.frame(width: 48, height: 48).accessibilityHidden(true)
                }
                Spacer(minLength: 16)
                VStack(spacing: 12) {
                    HStack {
                        if introTarget == nil, offersNextEpisode, let nextEpisode {
                            upNextButton(nextEpisode).playbackControl()
                        }
                        Spacer()
                        PlaybackSettingsMenu(menu: settingsMenu()) { presented in
                            showingOptions = presented
                            if presented {
                                controller.endBoost()
                                revealControls()
                            } else {
                                scheduleHide()
                            }
                        }
                        .frame(width: 44, height: 44).playbackControl()
                    }
                    timeline.playbackControl()
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.top, 12).padding(.bottom, 20)
            HStack(spacing: transportSpacing) {
                transportButton(
                    "Back 10 seconds", symbol: "gobackward.10", enabled: controller.timeline.isSeekable
                ) {
                    controller.skip(seconds: -10)
                }
                Button {
                    controller.togglePlayback()
                    revealControls()
                } label: {
                    Image(
                        systemName: controller.hasEnded
                            ? "arrow.counterclockwise" : controller.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.system(size: 38, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .offset(x: !controller.isPlaying && !controller.hasEnded ? 3 : 0)
                    .frame(width: 92, height: 92).contentShape(Circle())
                }.buttonStyle(.plain).glassEffect(.clear.interactive(), in: .circle)
                    .accessibilityLabel(
                        controller.hasEnded ? "Replay" : controller.isPlaying ? "Pause" : "Play"
                    )
                    .playbackControl()
                transportButton(
                    "Forward 10 seconds", symbol: "goforward.10", enabled: controller.timeline.isSeekable
                ) {
                    controller.skip(seconds: 10)
                }
            }.position(videoCenter)
        }
        .frame(width: size.width, height: size.height)
    }

    private func upNextButton(_ episode: Episode) -> some View {
        Button {
            request.onNextEpisode?(episode)
            close()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label("Up Next", systemImage: "play.rectangle.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                Text(episode.label + " · " + episode.displayTitle)
                    .font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: 280, alignment: .leading)
        }.buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityLabel("Up Next, \(episode.label), \(episode.displayTitle)")
            .accessibilityHint("Choose a stream for this episode")
    }

    private var timeline: some View {
        HStack(spacing: 12) {
            Text(timeLabel(displayedElapsed)).fixedSize()
                .accessibilityHidden(true)
            PlayerScrubber(
                progress: scrubbing ? scrubFraction : controller.timeline.progress,
                isEnabled: controller.timeline.isSeekable, isEditing: scrubbing,
                elapsedLabel: timeLabel(displayedElapsed),
                onScrub: { fraction in
                    controller.endBoost()
                    scrubbing = true
                    scrubFraction = fraction
                    interactionID += 1
                    revealControls()
                },
                onCommit: { fraction in
                    controller.seek(fraction: fraction)
                    scrubbing = false
                    revealControls()
                },
                onAdjust: { seconds in
                    controller.skip(seconds: seconds)
                    revealControls()
                })
            Text(
                controller.timeline.duration > 0
                    ? "−" + timeLabel(max(0, controller.timeline.duration - displayedElapsed))
                    : controller.isBuffering ? "−−:−−" : "LIVE"
            )
            .fixedSize().accessibilityHidden(true)
        }
        .font(.system(size: 15, weight: .medium)).monospacedDigit()
        .foregroundStyle(.white.opacity(0.65))
        .padding(.horizontal, 16)
        .glassEffect(.clear, in: .capsule)
    }

    private var displayedElapsed: Double {
        scrubbing ? scrubFraction * controller.timeline.duration : controller.timeline.elapsed
    }

    private func timeLabel(_ seconds: Double) -> String {
        let label = PlaybackTimeline.label(seconds: seconds)
        return label.count == 4 ? "0" + label : label
    }

    private func settingsMenu() -> UIMenu {
        let speed = UIMenu(
            title: "Playback speed", image: UIImage(systemName: "speedometer"), options: .singleSelection,
            children: PlaybackSpeed.values.map { value in
                settingsAction("\(value.formatted())×", selected: controller.speed == value) {
                    controller.setSpeed(value)
                }
            })
        let audio: UIMenuElement =
            controller.audioTracks.isEmpty
            ? UIAction(title: "Audio", image: UIImage(systemName: "waveform"), attributes: .disabled) { _ in }
            : UIMenu(
                title: "Audio", image: UIImage(systemName: "waveform"), options: .singleSelection,
                children: controller.audioTracks.map { track in
                    settingsAction(track.name, selected: controller.selectedAudio == track.id) {
                        controller.selectAudio(track.id)
                    }
                })
        let subtitles = UIMenu(
            title: "Subtitles", image: UIImage(systemName: "captions.bubble"), options: .singleSelection,
            children: [
                settingsAction("Off", selected: controller.selectedSubtitle == -1) {
                    controller.selectSubtitle(-1)
                }
            ]
                + controller.subtitleTracks.map { track in
                    settingsAction(track.name, selected: controller.selectedSubtitle == track.id) {
                        controller.selectSubtitle(track.id)
                    }
                })
        let fit = settingsAction(
            controller.fillsScreen ? "Fit video" : "Fill screen",
            symbol: controller.fillsScreen
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        ) {
            controller.setFill(!controller.fillsScreen)
        }
        let players = UIMenu(
            options: .displayInline,
            children: self.players.filter { $0 != .aether }.map { player in
                UIAction(
                    title: "Open in \(player.title)", image: UIImage(systemName: "arrow.up.right.square")
                ) { _ in switchPlayer(player) }
            })
        return UIMenu(children: [speed, audio, subtitles, fit, players])
    }

    private func settingsAction(
        _ title: String, symbol: String? = nil, selected: Bool = false, action: @escaping () -> Void
    ) -> UIAction {
        UIAction(
            title: title, image: symbol.flatMap { UIImage(systemName: $0) }, state: selected ? .on : .off
        ) { _ in
            action()
            revealControls()
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "play.slash").font(.largeTitle)
            Text("Unable to play").font(.title2.bold())
            Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") { switchPlayer(.aether) }.buttonStyle(.glassProminent).foregroundStyle(
                .black)
            if players.contains(where: { !$0.isInternal }) {
                Menu("Open in another player") {
                    ForEach(players.filter { !$0.isInternal }) { player in
                        Button("Open in \(player.title)") { switchPlayer(player) }
                    }
                }.buttonStyle(.glass)
            }
            Button("Choose another source") { close() }.buttonStyle(.glass)
        }.padding(28).frame(maxWidth: 480)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
    }

    private func glassButton(
        _ title: String, symbol: String, diameter: CGFloat = 48, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: diameter, height: diameter).contentShape(Circle())
        }.buttonStyle(.plain).glassEffect(.clear.interactive(), in: .circle).accessibilityLabel(title)
    }

    private func transportButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button {
            action()
            revealControls()
        } label: {
            Image(systemName: symbol).font(.system(size: 32, weight: .medium))
                .frame(width: 64, height: 64).contentShape(Circle())
        }.buttonStyle(.plain).glassEffect(.clear.interactive(), in: .circle)
            .disabled(!enabled).opacity(enabled ? 1 : 0.35).accessibilityLabel(title)
            .playbackControl()
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = false }
        } else {
            revealControls()
        }
    }

    private func revealControls() {
        guard applicationActive, controller.pictureInPictureState == .inactive else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controller.isPlaying, !controller.isBuffering, !controller.isBoosting,
            !scrubbing, !showingOptions, !voiceOver,
            applicationActive, controller.pictureInPictureState == .inactive
        else { return }
        let interaction = interactionID
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !scrubbing,
                !controller.isBoosting, interaction == interactionID
            else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    private func close() {
        hideTask?.cancel()
        controller.stop()
        adjustments.restoreBrightness()
        closePlayer()
    }

    private func switchPlayer(_ player: VideoPlayer) {
        hideTask?.cancel()
        controller.stop()
        adjustments.restoreBrightness()
        choosePlayer(player)
    }
}

private struct PlaybackControlFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

private extension View {
    func playbackControl() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: PlaybackControlFrames.self, value: [geometry.frame(in: .global)])
            }.allowsHitTesting(false)
        }
    }
}

private struct PlayerScrubber: View {
    let progress: Double
    let isEnabled: Bool
    let isEditing: Bool
    let elapsedLabel: String
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    let onAdjust: (Double) -> Void
    @GestureState private var dragging = false
    @State private var lastFraction: Double = 0
    @State private var committed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white.opacity(0.95))
                    .frame(width: geometry.size.width * min(1, max(0, progress)))
            }
            .frame(height: isEditing ? 10 : 8).clipShape(Capsule())
            .frame(height: 44).contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        guard isEnabled else { return }
                        committed = false
                        lastFraction = fraction(at: value.location.x, width: geometry.size.width)
                        onScrub(lastFraction)
                    }
                    .onEnded { value in
                        guard isEnabled else { return }
                        committed = true
                        onCommit(fraction(at: value.location.x, width: geometry.size.width))
                    }
            )
            .onChange(of: dragging) { _, active in
                // Gesture cancellation must release the auto-hide lock as well.
                if !active, isEditing, !committed { onCommit(lastFraction) }
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(elapsedLabel)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onAdjust(10)
            case .decrement: onAdjust(-10)
            @unknown default: break
            }
        }
    }

    private func fraction(at location: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, location / width)))
    }
}
