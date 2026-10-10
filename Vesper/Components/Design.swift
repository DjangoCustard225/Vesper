import SwiftUI
import VesperCore

enum Design {
    static let background = Color.black
    static let surface = Color(white: 0.075)
    static let posterWidth: CGFloat = 100
    static let posterSpacing: CGFloat = 12
    static let posterCornerRadius: CGFloat = 12
    static let heroHeight: CGFloat = 560
    static let columns = [GridItem(.adaptive(minimum: posterWidth, maximum: 140), spacing: posterSpacing, alignment: .top)]
}

struct Artwork: View {
    let url: String?
    var alignment: Alignment = .center
    var body: some View {
        CachedArtworkImage(url: url.flatMap { try? AddonURL.http($0) }) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            case .empty: placeholder.overlay { if url != nil { ProgressView().tint(.white.opacity(0.5)) } }
            default: placeholder
            }
        }
    }
    private var placeholder: some View {
        Rectangle().fill(Design.surface.gradient)
            .overlay { Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.18)) }
    }
}

struct ImmersiveArtwork: View {
    let url: String?
    var pullDistance: CGFloat = 0
    var body: some View {
        GeometryReader { proxy in
            let pull = max(0, pullDistance)
            let zoom = 1 + pull / max(proxy.size.height, 1)

            Artwork(url: url, alignment: .top)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .scaleEffect(zoom, anchor: .top)
                .frame(width: proxy.size.width, height: proxy.size.height + pull, alignment: .top)
                .clipped()
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                }
                .overlay {
                    LinearGradient(colors: [.clear, .black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom)
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ImmersiveScrollView<Content: View>: View {
    let artworkURL: String?
    let headerHeight: CGFloat
    var artworkURLs: [String?] = []
    var artworkOffset: CGFloat = 0
    @ViewBuilder var content: Content
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ScrollView { content }
            // Keep the scroll view in charge of its changing safe area as the native tab bar
            // contracts. Content can continue behind the bar without a clipped black strip.
            .scrollClipDisabled()
            .appScrollEdges()
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                scrollOffset = offset
            }
            .background(alignment: .top) {
                GeometryReader { viewport in
                    if headerHeight > 0 {
                        // Artwork remains outside the moving content, pinned during deep pulls.
                        if artworkURLs.isEmpty {
                            ImmersiveArtwork(url: artworkURL, pullDistance: max(0, -scrollOffset))
                                .frame(width: viewport.size.width, height: headerHeight)
                                .offset(y: -max(0, scrollOffset))
                        } else {
                            let offset = min(max(artworkOffset, 0), viewport.size.width * CGFloat(artworkURLs.count - 1))
                            let page = Int(offset / max(viewport.size.width, 1))
                            HStack(spacing: 0) {
                                ForEach(artworkURLs.indices, id: \.self) { index in
                                    Group {
                                        if abs(index - page) <= 1 {
                                            ImmersiveArtwork(url: artworkURLs[index], pullDistance: max(0, -scrollOffset))
                                        } else { Color.clear }
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

struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat? = nil
    var body: some View {
        Color.clear.aspectRatio(2 / 3, contentMode: .fit)
            .overlay { Artwork(url: item.poster) }
            .clipShape(RoundedRectangle(cornerRadius: Design.posterCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Design.posterCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: width, alignment: .topLeading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(item.releaseInfo ?? item.typeLabel)
    }
}

struct MediaGrid: View {
    let items: [MediaItem]
    var onNearEnd: (() -> Void)? = nil
    var onSelect: ((MediaItem) -> Void)? = nil
    var body: some View {
        LazyVGrid(columns: Design.columns, alignment: .leading, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                Group {
                    if let onSelect {
                        Button { onSelect(item) } label: { PosterCard(item: item) }
                    } else {
                        NavigationLink { DetailView(item: item) } label: { PosterCard(item: item) }
                    }
                }.buttonStyle(.plain)
                    .onAppear { if index >= items.count - 6 { onNearEnd?() } }
            }
        }
    }
}

struct CatalogHeading: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.title2.bold()).foregroundStyle(.primary)
            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.gray)
                .accessibilityHidden(true)
        }.padding(.vertical, 2).contentShape(Rectangle())
    }
}

struct ErrorNotice: View {
    let message: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary)
            if let retry { Button("Try again", action: retry).buttonStyle(.glass) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}

extension View {
    func accentButtonForeground() -> some View { foregroundStyle(.black) }
    func appScrollEdges() -> some View {
        scrollEdgeEffectHidden(true, for: .vertical)
            .scrollEdgeEffectStyle(.soft, for: .horizontal)
    }
    func appBackground() -> some View { background(Design.background).appScrollEdges() }
}

struct AutoPaginationTrigger: View {
    let load: () -> Void
    var body: some View {
        Color.clear.frame(height: 1).accessibilityHidden(true)
            .onScrollVisibilityChange(threshold: 0.01) { if $0 { load() } }
    }
}

struct PosterTitle: View {
    let name: String
    let logoURL: String?
    var preparedImage: Image? = nil
    var isLoading = false
    var body: some View {
        Group {
            if let preparedImage {
                titleImage(preparedImage)
            } else if isLoading {
                Color.clear.frame(height: 125)
            } else {
                CachedArtworkImage(url: logoURL.flatMap { try? AddonURL.http($0) }) { phase in
                    if let image = phase.image { titleImage(image) }
                    else { fallbackTitle }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isHeader)
    }
    private func titleImage(_ image: Image) -> some View {
        image.resizable().scaledToFit().frame(maxWidth: 340, maxHeight: 125)
            .shadow(color: .black.opacity(0.65), radius: 12, y: 4)
    }
    private var fallbackTitle: some View {
        Text(name)
            .font(.system(.largeTitle, design: .default, weight: .heavy))
            .tracking(-0.8).multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.7)
            .foregroundStyle(.white).shadow(color: .black.opacity(0.65), radius: 12, y: 4)
            .frame(maxWidth: 480)
    }
}
