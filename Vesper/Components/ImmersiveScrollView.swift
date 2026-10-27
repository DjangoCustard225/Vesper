import SwiftUI
import VesperCore

struct ImmersiveScrollView<Content: View>: View {
    let artwork: ImmersiveArtworkSource
    let headerHeight: CGFloat
    var artworks: [ImmersiveArtworkSource] = []
    var artworkPage: CGFloat = 0
    var isLandscape = false
    @ViewBuilder var content: Content
    @State private var offset = ImmersiveScrollOffset()

    var body: some View {
        ScrollView { content }
            // Keep the scroll view in charge of its changing safe area as the native tab bar
            // contracts. Content can continue behind the bar without a clipped black strip.
            .scrollClipDisabled()
            .scrollEdgeEffectHidden(true, for: .vertical)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(headerHeight, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, value in
                offset.value = value
            }
            .background(alignment: .top) {
                ImmersiveScrollBackdrop(
                    artwork: artwork, headerHeight: headerHeight, artworks: artworks,
                    artworkPage: artworkPage, isLandscape: isLandscape, offset: offset)
            }
    }
}

@MainActor @Observable
private final class ImmersiveScrollOffset {
    var value: CGFloat = 0
}

/// Only the backdrop observes per-frame scrolling. Catalogs and playback rows retain their layout.
private struct ImmersiveScrollBackdrop: View {
    let artwork: ImmersiveArtworkSource
    let headerHeight: CGFloat
    let artworks: [ImmersiveArtworkSource]
    let artworkPage: CGFloat
    let isLandscape: Bool
    let offset: ImmersiveScrollOffset

    var body: some View {
        let scrollOffset = offset.value
        return GeometryReader { viewport in
            if headerHeight > 0 {
                // Artwork remains outside the moving content, pinned during deep pulls.
                if artworks.isEmpty {
                    ImmersiveArtwork(
                        source: artwork, isLandscape: isLandscape, pullDistance: max(0, -scrollOffset)
                    )
                    .frame(width: viewport.size.width, height: headerHeight)
                    .offset(y: -max(0, scrollOffset))
                } else {
                    let horizontalOffset =
                        min(max(artworkPage, 0), CGFloat(artworks.count - 1)) * viewport.size.width
                    let page = Int(horizontalOffset / max(viewport.size.width, 1))
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
                    }.offset(x: -horizontalOffset, y: -max(0, scrollOffset))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
