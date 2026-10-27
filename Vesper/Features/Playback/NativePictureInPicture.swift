import AetherEngine
import AVKit
import Observation
import UIKit
import VesperCore

/// Owns one AVKit controller and retains its video source throughout the native transition.
@MainActor @Observable
final class NativePictureInPicture: NSObject {
    var state: AutomaticPictureInPicture.State { policy.state }
    private var policy = AutomaticPictureInPicture()

    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var nativeLayer: AVPlayerLayer?
    @ObservationIgnored private var softwareSource: SoftwarePiPSource?
    @ObservationIgnored private weak var owner: AetherPlaybackController?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var invalidating = false
    @ObservationIgnored private var invalidated = false
    @ObservationIgnored private var shutdownCompletions: [@MainActor () -> Void] = []
    @ObservationIgnored private var restorationCompletion: ((Bool) -> Void)?
    @ObservationIgnored private var restorationID: UUID?
    @ObservationIgnored private var lastPlayback: PlaybackSnapshot?

    private struct PlaybackSnapshot: Equatable {
        let paused: Bool
        let duration: Double
    }

    isolated deinit {
        backgroundTask?.cancel()
        shutdownTask?.cancel()
    }

    func configure(owner: AetherPlaybackController) {
        guard !invalidating, !invalidated else { return }
        self.owner = owner
        guard AVPictureInPictureController.isPictureInPictureSupported(), let engine = owner.engine else {
            return
        }
        // Replacing layers while AVKit is animating can flash a black frame or cancel the transition.
        if state == .inactive {
            updateSource(engine)
            controller?.canStartPictureInPictureAutomaticallyFromInline =
                owner.isPlaying && !owner.hasEnded && owner.error == nil && !owner.externalPlaybackActive
        }
        if softwareSource != nil {
            let snapshot = PlaybackSnapshot(paused: !owner.isPlaying, duration: owner.timeline.duration)
            if snapshot != lastPlayback {
                lastPlayback = snapshot
                controller?.invalidatePlaybackState()
            }
        }
    }

    private func updateSource(_ engine: AetherEngine) {
        if let layer = engine.nativePlayerLayer {
            guard nativeLayer !== layer else { return }
            replaceController(AVPictureInPictureController(playerLayer: layer))
            nativeLayer = layer
            softwareSource = nil
        } else if let source = engine.softwarePiPSource {
            if softwareSource?.layer !== source.layer {
                replaceController(
                    AVPictureInPictureController(
                        contentSource: .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: self)))
            }
            nativeLayer = nil
            softwareSource = source
        } else {
            replaceController(nil)
            nativeLayer = nil
            softwareSource = nil
        }
    }

    private func replaceController(_ replacement: AVPictureInPictureController?) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.delegate = nil
        controller = replacement
        controller?.delegate = self
        lastPlayback = nil
    }

    func enteredBackground() {
        guard !invalidating, let owner else { return }
        switch policy.backgrounded(
            eligible: controller?.isPictureInPicturePossible == true && owner.isPlaying
                && !owner.hasEnded && owner.error == nil,
            externalPlayback: owner.externalPlaybackActive)
        {
        case .keepPlaying: return
        case .pause: owner.pause()
        case .waitForSystem:
            guard backgroundTask == nil else { return }
            // Allow AVKit's willStart callback to arrive before pausing a declined handoff.
            backgroundTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.backgroundTask = nil
                if self.policy.graceExpired(), UIApplication.shared.applicationState == .background,
                    self.owner?.externalPlaybackActive != true
                {
                    self.owner?.pause()
                }
            }
        }
    }

    func enteredForeground() {
        cancelBackgroundHandoff()
        policy.foregrounded()
        // Reconcile a closed system window before deciding whether inline controls can return.
        if state == .active, controller?.isPictureInPictureActive != true {
            owner?.setPictureInPicture(false)
            policy.reset()
            if let owner { configure(owner: owner) }
        }
    }

    /// Release decoding and audio only after AVKit finishes animating the retained source away.
    func invalidate(completion: (@MainActor () -> Void)? = nil) {
        guard !invalidated else {
            completion?()
            return
        }
        if let completion { shutdownCompletions.append(completion) }
        guard !invalidating else { return }
        invalidating = true
        cancelBackgroundHandoff()
        completeRestoration(false)
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        guard state.isPresented || controller?.isPictureInPictureActive == true else {
            finishInvalidation()
            return
        }
        // Keep this bridge alive if its SwiftUI owner disappears during dismissal. The deadline is
        // only a teardown fallback for a missing AVKit callback, never an animation duration.
        shutdownTask = Task { [self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            finishInvalidation()
        }
        controller?.stopPictureInPicture()
    }

    private func cancelBackgroundHandoff() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    private func completeRestoration(_ restored: Bool) {
        let completion = restorationCompletion
        restorationCompletion = nil
        restorationID = nil
        completion?(restored)
    }

    private func finishInvalidation() {
        guard !invalidated else { return }
        invalidated = true
        invalidating = false
        shutdownTask?.cancel()
        shutdownTask = nil
        let previous = controller
        replaceController(nil)
        if previous?.isPictureInPictureActive == true { previous?.stopPictureInPicture() }
        nativeLayer = nil
        softwareSource = nil
        owner?.setPictureInPicture(false)
        policy.reset()
        let completions = shutdownCompletions
        shutdownCompletions = []
        for completion in completions { completion() }
    }
}

extension NativePictureInPicture: @MainActor AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller else { return }
        cancelBackgroundHandoff()
        policy.willStart()
        owner?.setPictureInPicture(true)
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller else { return }
        policy.started()
        if invalidating { controller.stopPictureInPicture() }
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller else { return }
        policy.willStop()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller else { return }
        owner?.setPictureInPicture(false)
        let shouldPause = policy.stopped()
        completeRestoration(false)
        if invalidating {
            finishInvalidation()
        } else if let owner {
            if shouldPause, UIApplication.shared.applicationState == .background { owner.pause() }
            configure(owner: owner)
        }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
    ) {
        guard self.controller === controller else { return }
        cancelBackgroundHandoff()
        completeRestoration(false)
        owner?.setPictureInPicture(false)
        policy.reset()
        if invalidating {
            finishInvalidation()
        } else if UIApplication.shared.applicationState == .background {
            owner?.pause()
        }
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void
    ) {
        guard self.controller === controller, !invalidating, let owner else {
            completion(false)
            return
        }
        completeRestoration(false)
        restorationCompletion = completion
        let request = UUID()
        restorationID = request
        policy.restoring()
        owner.restorePictureInPicturePresentation { [weak self, weak controller] restored in
            guard let self, let controller, self.controller === controller,
                self.state == .restoring, self.restorationID == request, !self.invalidating
            else { return }
            if !restored { self.policy.restorationFailed() }
            self.completeRestoration(restored)
        }
    }
}

extension NativePictureInPicture: @MainActor AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard self.controller === controller, !invalidating, let owner else { return }
        if playing {
            if !owner.isPlaying { owner.togglePlayback() }
        } else {
            owner.pause()
        }
        controller.invalidatePlaybackState()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController)
        -> CMTimeRange
    {
        guard self.controller === controller else { return .invalid }
        return softwareSource?.timeRange() ?? .invalid
    }

    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        guard self.controller === controller else { return true }
        return softwareSource?.isPaused ?? true
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion: @escaping () -> Void
    ) {
        guard self.controller === controller, !invalidating, let owner,
            skipInterval.seconds.isFinite
        else {
            completion()
            return
        }
        Task {
            await owner.skipFromPictureInPicture(seconds: skipInterval.seconds)
            if self.controller === controller, !self.invalidating { controller.invalidatePlaybackState() }
            completion()
        }
    }
}
