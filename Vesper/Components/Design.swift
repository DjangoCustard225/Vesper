import SwiftUI
import VesperCore

enum Design {
    static let background = Color.black
    static let surface = Color(white: 0.075)
    static let posterWidth: CGFloat = 100
    static let posterSpacing: CGFloat = 12
    static let posterCornerRadius: CGFloat = 12
    static let minimumHitTarget: CGFloat = 44
    static let heroHeight: CGFloat = 560

    static func landscapeHeroHeight(for height: CGFloat) -> CGFloat { min(420, max(280, height * 0.78)) }

    static func landscapeDetailHeight(for height: CGFloat) -> CGFloat { min(360, max(240, height * 0.68)) }
    static let columns = [
        GridItem(.adaptive(minimum: posterWidth, maximum: 140), spacing: posterSpacing, alignment: .top)
    ]
}

extension View {
    func accentButtonForeground() -> some View { foregroundStyle(.black) }

    /// Shared scroll styling. Also hides scroll bars, which the app root does too, so sheets and
    /// covers stay consistent however they inherit the environment.
    func appScrollEdges() -> some View {
        scrollEdgeEffectHidden(false, for: .vertical)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollIndicators(.hidden)
    }

    func appBackground() -> some View { background(Design.background).appScrollEdges() }
}
