import SwiftUI
import UIKit
import Observation
import UsenetEngine
import VesperCore

struct UsenetPreparationView: View {
    let title: String
    let subtitle: String?
    let poster: String?
    let backdrop: String?
    var stage: UsenetPreparationStage
    var cancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: String {
        switch stage {
        case .preparing: "Preparing stream…"
        case .fetchingNZB: "Fetching release…"
        case .readingNZB: "Reading release…"
        case .checkingFiles: "Checking video files…"
        case .openingVideo: "Opening video…"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let layout =
                landscape ? AnyLayout(HStackLayout(spacing: 36)) : AnyLayout(VStackLayout(spacing: 24))
            let posterHeight = min(420, max(180, geometry.size.height - 48))
            ZStack {
                ScrollView {
                    layout {
                        if let poster, let url = try? AddonURL.http(poster) {
                            CachedArtworkImage(
                                url: url,
                                decodeSize: ArtworkDecodeSize(width: 720, height: 1080, scale: 1),
                                fadesIn: true
                            ) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Color.white.opacity(0.06)
                                }
                            }
                            .frame(width: posterHeight * 2 / 3, height: posterHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15)) }
                            .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
                            .accessibilityHidden(true)
                        }
                        VStack(spacing: 22) {
                            VStack(spacing: 8) {
                                Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let subtitle, !subtitle.isEmpty {
                                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(3)
                                }
                            }
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small).accessibilityHidden(true)
                                Text(status).font(.subheadline.weight(.medium))
                            }
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .glassEffect(.regular, in: .capsule)
                            .accessibilityElement(children: .combine)
                            Button("Cancel", action: cancel)
                                .font(.body.weight(.medium)).padding(.horizontal, 24).frame(minHeight: 44)
                                .buttonStyle(.glass).buttonBorderShape(.capsule)
                        }.frame(maxWidth: 340)
                    }
                    .padding(24).frame(maxWidth: 960).frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize, axes: .vertical)
            }
        }
        .background {
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    // Pre-blurred bitmap: a live blur would re-render with every progress update.
                    BlurredArtwork(url: (backdrop ?? poster).flatMap { try? AddonURL.http($0) }, amount: 0.03)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .overlay(.black.opacity(0.5))
                    LinearGradient(
                        colors: [.black.opacity(0.1), .black.opacity(0.85)],
                        startPoint: .top, endPoint: .bottom)
                }
            }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        }
        .foregroundStyle(.white).tint(.white).preferredColorScheme(.dark)
        .accessibilityAddTraits(.isModal).accessibilityAction(.escape, cancel)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stage)
    }
}

/// UIKit queries this controller's landscape policy for the full-screen preparation cover.
struct UsenetPreparationScreen: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPresented: Bool
    let isActive: @MainActor () -> Bool
    let currentStage: @MainActor () -> UsenetPreparationStage
    let content: UsenetPreparationView
    let onDismiss: () -> Void
    func makeUIViewController(context: Context) -> Presenter {
        let presenter = Presenter()
        presenter.update = self
        return presenter
    }
    func updateUIViewController(_ presenter: Presenter, context: Context) {
        presenter.update = self
        presenter.synchronize()
    }
    static func dismantleUIViewController(_ presenter: Presenter, coordinator: ()) { presenter.finish() }

    final class Presenter: UIViewController {
        var update: UsenetPreparationScreen?
        private var screen: UsenetPreparationController?
        private var dismissing = false
        private var cancelled = false
        private var observationID = UUID()
        override func viewDidLoad() {
            super.viewDidLoad()
            NotificationCenter.default.addObserver(
                self, selector: #selector(synchronize), name: UIApplication.didBecomeActiveNotification,
                object: nil)
        }
        isolated deinit { NotificationCenter.default.removeObserver(self) }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            synchronize()
        }
        @objc func synchronize() {
            guard !dismissing, let update else { return }
            let observation = UUID()
            observationID = observation
            let (active, stage) = withObservationTracking {
                (update.isActive(), update.currentStage())
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.observationID == observation else { return }
                    self.synchronize()
                }
            }
            if cancelled {
                if screen != nil { finish() } else if !active { cancelled = false }
                return
            }
            guard active else { finish(); return }
            var content = update.content
            content.stage = stage
            let cancel = content.cancel
            content.cancel = { [weak self] in
                guard let self, !self.cancelled else { return }
                self.cancelled = true
                cancel()
                self.finish()
            }
            if let screen { screen.rootView = content; return }
            guard UIApplication.shared.applicationState == .active, viewIfLoaded?.window != nil else {
                return
            }
            var presenter: UIViewController = self
            while let parent = presenter.parent { presenter = parent }
            guard presenter.presentedViewController == nil, !presenter.isBeingDismissed else { return }
            if presenter.isBeingPresented {
                presenter.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
                    DispatchQueue.main.async { self?.synchronize() }
                }
                return
            }
            let screen = UsenetPreparationController(rootView: content)
            screen.modalPresentationStyle = .fullScreen
            screen.isModalInPresentation = true
            self.screen = screen
            presenter.present(screen, animated: !update.reduceMotion) { [weak self] in
                self?.synchronize()
            }
        }
        func finish() {
            guard !dismissing else { return }
            guard let screen else { update?.onDismiss(); return }
            // A fast lookup or cancellation can finish while the presentation animation is running.
            // Its completion calls synchronize again after UIKit can safely dismiss the screen.
            guard !screen.isBeingPresented else { return }
            dismissing = true
            screen.dismiss(animated: update?.reduceMotion != true) { [weak self] in
                guard let self else { return }
                self.screen = nil; self.dismissing = false
                self.update?.onDismiss()
                if self.update?.isActive() == true && !self.cancelled { self.synchronize() }
            }
        }
    }
}

final class UsenetPreparationController: UIHostingController<UsenetPreparationView> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
    }
}
