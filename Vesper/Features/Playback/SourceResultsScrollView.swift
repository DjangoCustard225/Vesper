import SwiftUI

private struct SourceScrollEffectsEnabledKey: EnvironmentKey { static let defaultValue = false }
private struct SourceScrollAtTopKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    fileprivate var sourceScrollEffectsEnabled: Bool {
        get { self[SourceScrollEffectsEnabledKey.self] }
        set { self[SourceScrollEffectsEnabledKey.self] = newValue }
    }
    fileprivate var sourceScrollAtTop: Bool {
        get { self[SourceScrollAtTopKey.self] }
        set { self[SourceScrollAtTopKey.self] = newValue }
    }
}

struct SourceResultsScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hasStartedScrolling = false
    @State private var isAnimatingScroll = false
    @State private var isUserScrolling = false
    @State private var isAtTop = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) { content }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 20)
                .environment(\.sourceScrollEffectsEnabled, hasStartedScrolling && !isAnimatingScroll)
                .environment(\.sourceScrollAtTop, isAtTop)
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top <= 1 } action: { _, atTop in
            isAtTop = atTop
            if !atTop, isUserScrolling { hasStartedScrolling = true }
        }
        .onScrollPhaseChange { _, phase in
            let animating = phase == .animating
            let userScrolling = phase == .interacting || phase == .decelerating
            hasStartedScrolling = !animating && (hasStartedScrolling || userScrolling)
            isAnimatingScroll = animating; isUserScrolling = userScrolling
        }
        .contentMargins(.bottom, 48, for: .scrollContent)
        .appBackground()
    }
}

struct SourceCardScrollEffect: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sourceScrollEffectsEnabled) private var effectsEnabled
    @Environment(\.sourceScrollAtTop) private var isAtTop

    func body(content: Content) -> some View {
        let active = effectsEnabled && !reduceMotion
        let atTop = isAtTop
        return content.scrollTransition(
            topLeading: .interactive.threshold(.visible.inset(by: 70)),
            bottomTrailing: .interactive.threshold(.visible.inset(by: 70)), axis: .vertical
        ) { effect, phase in
            let applyEffect = active && !phase.isIdentity && !(atTop && phase == .topLeading)
            return effect.opacity(applyEffect ? 0.65 : 1).scaleEffect(applyEffect ? 0.92 : 1)
        }
    }
}
