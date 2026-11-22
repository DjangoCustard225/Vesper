import SwiftUI
import VesperCore

struct ImmersiveScrollView<Content: View>: View {
    let artwork: ImmersiveArtworkSource
    let headerHeight: CGFloat
    var artworks: [ImmersiveArtworkSource] = []
    /// The hero carousel's page position. Only the backdrop reads it, so paging does not
    /// re-evaluate the page that owns this view on every frame.
    var artworkPage: ImmersiveArtworkPage? = nil
    var isLandscape = false
    var usesPortraitPoster = false
    /// How far the artwork's blurred fade continues past the header, behind the first content rows.
    var bottomBleed: CGFloat = 0
    /// Softly fade content under the top bar so it never overlaps the bar's buttons.
    var fadesUnderTopBar = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var content: Content
    @State private var offset = ImmersiveScrollOffset()
    /// Flips only when crossing the threshold, so the page body is not re-evaluated every frame.
    @State private var scrolled = false

    var body: some View {
        ScrollView { content }
            // Keep the scroll view in charge of its changing safe area as the native tab bar
            // contracts. Content can continue behind the bar without a clipped black strip.
            .scrollClipDisabled()
            .scrollEdgeEffectHidden(true, for: .bottom)
            // At rest the artwork reaches the top unobstructed; fade only once content moves under the bar.
            .scrollEdgeEffectHidden(!(fadesUnderTopBar && scrolled), for: .top)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // Clamped so per-frame updates stop once the header has scrolled away.
                min(headerHeight + bottomBleed, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, value in
                offset.value = value
                let isScrolled = value > 4
                if isScrolled != scrolled { scrolled = isScrolled }
            }
            .background(alignment: .top) {
                ImmersiveScrollBackdrop(
                    artwork: artwork, headerHeight: headerHeight, artworks: artworks,
                    artworkPage: artworkPage, isLandscape: isLandscape,
                    usesPortraitPoster: usesPortraitPoster, bottomBleed: headerHeight > 0 ? bottomBleed : 0,
                    zoomsOnPull: !reduceMotion, offset: offset)
            }
    }
}

@MainActor @Observable
private final class ImmersiveScrollOffset {
    var value: CGFloat = 0
}

/// A carousel's fractional page, shared by reference between the carousel and the backdrop.
@MainActor @Observable
final class ImmersiveArtworkPage {
    var value: CGFloat = 0
}

/// Only the backdrop observes per-frame scrolling. Catalogs and playback rows retain their layout.
private struct ImmersiveScrollBackdrop: View {
    let artwork: ImmersiveArtworkSource
    let headerHeight: CGFloat
    let artworks: [ImmersiveArtworkSource]
    let artworkPage: ImmersiveArtworkPage?
    let isLandscape: Bool
    let usesPortraitPoster: Bool
    let bottomBleed: CGFloat
    let zoomsOnPull: Bool
    let offset: ImmersiveScrollOffset

    var body: some View {
        let scrollOffset = offset.value
        // The artwork moves with the content and zooms only on a pull at the top.
        let artworkOffset = max(0, scrollOffset)
        let pullDistance = zoomsOnPull ? max(0, -scrollOffset) : 0
        let visibleHeight = max(0, headerHeight + bottomBleed - scrollOffset)
        return GeometryReader { viewport in
            if headerHeight > 0 {
                // Artwork remains outside the moving content, pinned during deep pulls.
                if artworks.isEmpty {
                    ImmersiveArtwork(
                        source: artwork, isLandscape: isLandscape, pullDistance: pullDistance,
                        usesPortraitPoster: usesPortraitPoster
                    )
                    .frame(width: viewport.size.width, height: headerHeight + bottomBleed)
                    .offset(y: -artworkOffset)
                } else {
                    let horizontalOffset =
                        min(max(artworkPage?.value ?? 0, 0), CGFloat(artworks.count - 1))
                        * viewport.size.width
                    let page = Int(horizontalOffset / max(viewport.size.width, 1))
                    HStack(spacing: 0) {
                        ForEach(artworks.indices, id: \.self) { index in
                            Group {
                                if abs(index - page) <= 1 {
                                    ImmersiveArtwork(
                                        source: artworks[index], isLandscape: isLandscape,
                                        pullDistance: pullDistance)
                                } else {
                                    Color.clear
                                }
                            }.frame(width: viewport.size.width, height: headerHeight)
                        }
                    }.offset(x: -horizontalOffset, y: -artworkOffset)
                }
            }
        }
        // Clip to the part of the header (and its fade) still on screen. A clipping frame is a
        // plain layer bound; a mask that changes every frame forces an offscreen render.
        .frame(height: visibleHeight, alignment: .top).clipped()
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
