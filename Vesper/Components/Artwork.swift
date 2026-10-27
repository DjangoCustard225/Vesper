import SwiftUI
import VesperCore

struct ImmersiveArtworkSource {
    let backdrop: String?
    let poster: String?

    var preferred: String? { backdrop ?? poster }
}

struct Artwork: View {
    let url: String?
    var alignment: Alignment = .center
    var retainsPreviousImage = false
    var decodeSize: ArtworkDecodeSize? = nil

    private var imageURL: URL? { url.flatMap { try? AddonURL.http($0) } }

    var body: some View {
        CachedArtworkImage(
            url: imageURL, decodeSize: decodeSize, fadesIn: true, retainsPreviousImage: retainsPreviousImage
        ) {
            phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            case .empty: ArtworkPlaceholder(isLoading: imageURL != nil)
            default: ArtworkPlaceholder()
            }
        }
    }
}

private struct ArtworkPlaceholder: View {
    var isLoading = false

    var body: some View {
        Rectangle().fill(Design.surface.gradient)
            .overlay { Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.18)) }
            .overlay { if isLoading { ProgressView().tint(.white.opacity(0.5)) } }
    }
}

struct ImmersiveArtwork: View {
    let source: ImmersiveArtworkSource
    var isLandscape = false
    var pullDistance: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let pull = max(0, pullDistance)
            let zoom = 1 + pull / max(proxy.size.height, 1)

            Group {
                if isLandscape {
                    landscapeArtwork(size: proxy.size)
                } else {
                    Artwork(url: source.preferred, alignment: .top, retainsPreviousImage: true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .scaleEffect(zoom, anchor: .top)
            .frame(width: proxy.size.width, height: proxy.size.height + pull, alignment: .top)
            .clipped()
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
            }
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black], startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                if isLandscape {
                    LinearGradient(
                        colors: [.black.opacity(0.78), .black.opacity(0.28), .clear],
                        startPoint: .leading, endPoint: .trailing)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func landscapeArtwork(size: CGSize) -> some View {
        let url = source.preferred.flatMap { try? AddonURL.http($0) }
        CachedArtworkImage(url: url, fadesIn: true, retainsPreviousImage: true) { phase in
            if let image = phase.image {
                let dimensions = url.flatMap { ArtworkPipeline.shared.cachedImage(for: $0)?.size }
                let wide =
                    source.backdrop != nil && (dimensions.map { $0.width / max($0.height, 1) >= 1.2 } ?? true)
                if wide {
                    image.resizable().scaledToFill().frame(width: size.width, height: size.height).clipped()
                } else {
                    ZStack(alignment: .trailing) {
                        image.resizable().scaledToFill().frame(width: size.width, height: size.height)
                            .blur(radius: 32).overlay(.black.opacity(0.55)).clipped()
                        image.resizable().scaledToFit()
                            .frame(width: min(size.width * 0.34, 250), height: size.height * 0.88)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.trailing, max(20, size.width * 0.06))
                    }.frame(width: size.width, height: size.height).clipped()
                }
            } else {
                ArtworkPlaceholder(isLoading: url != nil && phase.error == nil)
                    .frame(width: size.width, height: size.height)
            }
        }
    }
}
