import SwiftUI
import UIKit
import VesperCore

/// Present the player as the actual full-screen controller so UIKit queries its orientation policy.
struct BuiltInPlayerPresentation: UIViewControllerRepresentable {
    @Binding var request: PlaybackRequest?
    let gesturePreferences: PlayerGesturePreferences
    let players: [VideoPlayer]
    let onDismiss: () -> Void
    let choosePlayer: (VideoPlayer) -> Void

    func makeUIViewController(context: Context) -> Presenter {
        let presenter = Presenter()
        presenter.update = self
        return presenter
    }

    func updateUIViewController(_ presenter: Presenter, context: Context) {
        presenter.update = self
        presenter.synchronize()
    }

    static func dismantleUIViewController(_ presenter: Presenter, coordinator: ()) {
        presenter.finish()
    }

    @MainActor final class Presenter: UIViewController {
        var update: BuiltInPlayerPresentation?
        private var player: LandscapePlayerController?
        private var dismissing = false
        private var previousOrientation = UIInterfaceOrientation.unknown
        private weak var playbackScene: UIWindowScene?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            synchronize()
        }

        func synchronize() {
            guard !dismissing else { return }
            guard let update, let request = update.request else {
                finish()
                return
            }
            if let player {
                if player.rootView.players != update.players { player.rootView.players = update.players }
                return
            }
            guard viewIfLoaded?.window != nil else { return }
            // Present from the active sheet or navigation controller containing the sources.
            var presenter: UIViewController = self
            while let parent = presenter.parent { presenter = parent }
            guard presenter.presentedViewController == nil, !presenter.isBeingDismissed else { return }
            // An automatic resume can resolve before the sources sheet finishes opening.
            if presenter.isBeingPresented {
                presenter.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                    DispatchQueue.main.async { self?.synchronize() }
                }
                return
            }
            playbackScene = view.window?.windowScene
            previousOrientation = playbackScene?.effectiveGeometry.interfaceOrientation ?? .unknown
            let root = BuiltInPlayerView(
                request: request, gesturePreferences: update.gesturePreferences, players: update.players,
                closePlayer: { [weak self] in
                    self?.update?.request = nil
                    self?.finish()
                },
                choosePlayer: { [weak self] choice in
                    self?.update?.choosePlayer(choice)
                    self?.finish()
                },
                restorePresentation: { [weak self] completion in
                    guard let self, let player = self.player, !self.dismissing else {
                        completion(false)
                        return
                    }
                    player.restorePictureInPicturePresentation(completion: completion)
                })
            let player = LandscapePlayerController(rootView: root)
            if previousOrientation.isLandscape { player.startingOrientation = previousOrientation }
            player.modalPresentationStyle = .fullScreen
            player.onDismiss = { [weak self] in self?.didDismiss() }
            self.player = player
            presenter.present(player, animated: true)
        }

        func finish() {
            guard let player, !dismissing else { return }
            dismissing = true
            player.dismiss(animated: true) { [weak self] in self?.didDismiss() }
        }

        private func didDismiss() {
            guard let player else { return }
            let scene = playbackScene
            playbackScene = nil
            self.player = nil
            dismissing = false
            player.onDismiss = nil
            update?.request = nil
            // Restore the orientation used before playback, including portrait.
            let mask: UIInterfaceOrientationMask
            switch previousOrientation {
            case .portrait: mask = .portrait
            case .portraitUpsideDown: mask = .portraitUpsideDown
            case .landscapeLeft: mask = .landscapeLeft
            case .landscapeRight: mask = .landscapeRight
            default: mask = .allButUpsideDown
            }
            scene?.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            update?.onDismiss()
        }
    }
}

@MainActor private final class LandscapePlayerController: UIHostingController<BuiltInPlayerView> {
    var onDismiss: (() -> Void)?
    var startingOrientation = UIInterfaceOrientation.landscapeRight

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { startingOrientation }

    func restorePictureInPicturePresentation(completion: @escaping @MainActor (Bool) -> Void) {
        guard isViewLoaded, view.window != nil, !isBeingDismissed else {
            completion(false)
            return
        }
        setNeedsUpdateOfSupportedInterfaceOrientations()
        let settled: @MainActor (Bool) -> Void = { [weak self] cancelled in
            guard let self, !cancelled, !self.isBeingDismissed,
                let window = self.viewIfLoaded?.window, !self.view.bounds.isEmpty
            else {
                completion(false)
                return
            }
            UIView.performWithoutAnimation { window.layoutIfNeeded() }
            completion(true)
        }
        // AVKit needs the real destination frame before its return animation starts. Keep the
        // existing controller mounted and wait for any UIKit rotation/presentation to settle.
        if let transitionCoordinator,
            transitionCoordinator.animate(alongsideTransition: nil, completion: { settled($0.isCancelled) })
        {
            return
        }
        DispatchQueue.main.async { settled(false) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { onDismiss?() }
    }
}
