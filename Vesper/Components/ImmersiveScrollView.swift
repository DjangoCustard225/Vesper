import SwiftUI
import VesperCore

struct ImmersiveScrollView<Content: View>: View {
    let artwork: ImmersiveArtworkSource
    let headerHeight: CGFloat
    var artworks: [ImmersiveArtworkSource] = []
    var artworkPage: CGFloat = 0
    var isLandscape = false
    @ViewBuilder var content: Content
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ScrollView { content }
            // Keep the scroll view in charge of its changing safe area as the native tab bar
            // contracts. Content can continue behind the bar without a clipped black strip.
            .scrollClipDisabled()
            .scrollEdgeEffectHidden(true, for: .vertical)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scrollOffset = offset
            }
            .background(alignment: .top) {
                GeometryReader { viewport in
                    if headerHeight > 0 {
                        // Artwork remains outside the moving content, pinned during deep pulls.
                        if artworks.isEmpty {
                            ImmersiveArtwork(
                                source: artwork, isLandscape: isLandscape, pullDistance: max(0, -scrollOffset)
                            )
                            .frame(width: viewport.size.width, height: headerHeight)
                            .offset(y: -max(0, scrollOffset))
                        } else {
                            let offset =
                                min(max(artworkPage, 0), CGFloat(artworks.count - 1)) * viewport.size.width
                            let page = Int(offset / max(viewport.size.width, 1))
                            HStack(spacing: 0) {
                                ForEach(artworks.indices, id: \.self) { index in
                                    Group {
                                        if abs(index - page) <= 1 {
                                            ImmersiveArtwork(
                                                source: artworks[index], isLandscape: isLandscape,
                                                pullDistance: max(0, -scrollOffset))
                                        } else {
                                            Color.clear
                                        }
                                    }.frame(width: viewport.size.width, height: headerHeight)
                                }
                            }.offset(x: -offset, y: -max(0, scrollOffset))
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}
