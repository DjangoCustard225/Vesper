import SwiftUI
import QuartzCore
import UIKit

struct MPVVideoSurface: UIViewRepresentable {
    let controller: MPVPlaybackController

    func makeUIView(context: Context) -> MPVSurfaceView {
        let view = MPVSurfaceView()
        view.backgroundColor = .black
        view.isOpaque = true
        view.ready = { [weak controller] layer in controller?.attach(to: layer) }
        return view
    }

    func updateUIView(_ uiView: MPVSurfaceView, context: Context) {}
}

final class MPVSurfaceView: UIView {
    override class var layerClass: AnyClass { MPVMetalLayer.self }
    var ready: ((CAMetalLayer) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window, bounds.width > 1, bounds.height > 1,
              let metal = layer as? CAMetalLayer else { return }
        let scale = window.screen.scale
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metal.framebufferOnly = true
        metal.isOpaque = true
        ready?(metal)
        ready = nil
    }
}

final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK may request a temporary 1×1 drawable during presentation.
    // Retaining the actual viewport prevents a flicker or a stuck black frame.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue }
        }
    }

    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread { super.wantsExtendedDynamicRangeContent = newValue }
            else { DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue } }
        }
    }
}
