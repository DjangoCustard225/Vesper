import AVFAudio
import MediaPlayer
import SwiftUI
import UIKit

struct PlayerHoldGesture: UIGestureRecognizerRepresentable {
    let enabled: Bool
    let excludedFrames: [CGRect]
    let holdChanged: (Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(excludedFrames: excludedFrames)
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 20
        hold.numberOfTouchesRequired = 1
        hold.delegate = context.coordinator
        hold.isEnabled = enabled
        return hold
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        context.coordinator.excludedFrames = excludedFrames
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began: holdChanged(true)
        case .ended, .cancelled, .failed: holdChanged(false)
        default: break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var excludedFrames: [CGRect]

        init(excludedFrames: [CGRect]) {
            self.excludedFrames = excludedFrames
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            allowsPlayerGestureTouch(touch, excluding: excludedFrames)
        }
    }
}

enum PlayerSwipeSide { case brightness, volume }

@MainActor final class PlayerSystemAdjustments {
    let volumeView: MPVolumeView = {
        let view = MPVolumeView()
        view.showsVolumeSlider = true
        return view
    }()

    private weak var brightnessScreen: UIScreen?
    private var previousBrightness: CGFloat?
    private var lastGestureBrightness: CGFloat?
    private var gestureStart: CGFloat = 0

    func begin(_ side: PlayerSwipeSide) {
        switch side {
        case .brightness:
            guard let screen = volumeView.window?.windowScene?.screen else { return }
            brightnessScreen = screen
            let current = screen.brightness
            if previousBrightness == nil { previousBrightness = current }
            gestureStart = current
        case .volume:
            volumeView.layoutIfNeeded()
            gestureStart = volumeSlider().map { CGFloat($0.value) }
                ?? CGFloat(AVAudioSession.sharedInstance().outputVolume)
        }
    }

    func adjust(_ side: PlayerSwipeSide, fraction: CGFloat) {
        let value = min(1, max(0, gestureStart + fraction))
        switch side {
        case .brightness:
            guard let brightnessScreen else { return }
            brightnessScreen.brightness = value
            lastGestureBrightness = value
        case .volume:
            guard let slider = volumeSlider() else { return }
            slider.setValue(Float(value), animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }

    func restoreBrightness() {
        defer { previousBrightness = nil; lastGestureBrightness = nil }
        guard let brightnessScreen, let previousBrightness, let lastGestureBrightness,
              abs(brightnessScreen.brightness - lastGestureBrightness) < 0.01 else { return }
        brightnessScreen.brightness = previousBrightness
    }

    private func volumeSlider() -> UISlider? {
        func find(in view: UIView) -> UISlider? {
            if let slider = view as? UISlider { return slider }
            for subview in view.subviews {
                if let slider = find(in: subview) { return slider }
            }
            return nil
        }
        return find(in: volumeView)
    }
}

struct SystemVolumeAttachment: UIViewRepresentable {
    let adjustments: PlayerSystemAdjustments
    func makeUIView(context: Context) -> MPVolumeView { adjustments.volumeView }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

struct PlayerAdjustmentCapture: UIViewRepresentable {
    let brightnessEnabled: Bool
    let volumeEnabled: Bool
    let began: (PlayerSwipeSide) -> Void
    let changed: (PlayerSwipeSide, CGFloat) -> Void
    let ended: () -> Void

    func makeUIView(context: Context) -> PlayerAdjustmentCaptureView {
        let view = PlayerAdjustmentCaptureView(frame: .zero)
        view.configure(self)
        return view
    }

    func updateUIView(_ view: PlayerAdjustmentCaptureView, context: Context) {
        view.configure(self)
    }

    static func dismantleUIView(_ view: PlayerAdjustmentCaptureView, coordinator: ()) {
        view.detach()
    }
}

@MainActor final class PlayerAdjustmentCaptureView: UIView, UIGestureRecognizerDelegate {
    private let pan = UIPanGestureRecognizer()
    private weak var installedWindow: UIWindow?
    private var brightnessEnabled = false
    private var volumeEnabled = false
    private var began: ((PlayerSwipeSide) -> Void)?
    private var changed: ((PlayerSwipeSide, CGFloat) -> Void)?
    private var ended: (() -> Void)?
    private var pendingSide: PlayerSwipeSide?
    private var activeSide: PlayerSwipeSide?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = self
        pan.addTarget(self, action: #selector(handlePan(_:)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard installedWindow !== window else { return }
        detach()
        installedWindow = window
        window?.addGestureRecognizer(pan)
    }

    func configure(_ capture: PlayerAdjustmentCapture) {
        brightnessEnabled = capture.brightnessEnabled
        volumeEnabled = capture.volumeEnabled
        began = capture.began
        changed = capture.changed
        ended = capture.ended
        pan.isEnabled = brightnessEnabled || volumeEnabled
    }

    func detach() {
        if activeSide != nil { ended?() }
        activeSide = nil
        pendingSide = nil
        installedWindow?.removeGestureRecognizer(pan)
        installedWindow = nil
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let window = installedWindow else { return }
        switch recognizer.state {
        case .began:
            guard let side = pendingSide else { return }
            activeSide = side
            began?(side)
            changed?(side, -recognizer.translation(in: window).y / max(1, window.bounds.height))
        case .changed:
            guard let side = activeSide else { return }
            changed?(side, -recognizer.translation(in: window).y / max(1, window.bounds.height))
        case .ended, .cancelled, .failed:
            if activeSide != nil { ended?() }
            activeSide = nil
            pendingSide = nil
        default: break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        pendingSide = nil
        guard let window = installedWindow else { return false }
        // Select the side from the first touch in full-window coordinates.
        let side: PlayerSwipeSide = touch.location(in: window).x < window.bounds.midX ? .brightness : .volume
        guard side == .brightness ? brightnessEnabled : volumeEnabled else { return false }
        pendingSide = side
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let window = installedWindow, let pendingSide else { return false }
        guard pendingSide == .brightness ? brightnessEnabled : volumeEnabled else { return false }
        let offset = pan.translation(in: window)
        return abs(offset.y) >= abs(offset.x) * 0.8
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UILongPressGestureRecognizer
    }
}

private func allowsPlayerGestureTouch(_ touch: UITouch, excluding frames: [CGRect]) -> Bool {
    // SwiftUI buttons and the timeline can share their hosting UIView. Test
    // their actual frames as well as UIKit controls before claiming a touch.
    let point = touch.location(in: touch.window)
    guard !frames.contains(where: { $0.contains(point) }) else { return false }
    var view = touch.view
    while let current = view {
        if current is UIControl { return false }
        view = current.superview
    }
    return true
}
