import SwiftUI
import VesperCore

struct PosterCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    let item: MediaItem
    var width: CGFloat? = nil

    private var watched: Bool { WatchProgress.supports(item) && store.isWatched(item) }

    var body: some View {
        Color.clear.aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    Artwork(
                        url: item.poster,
                        decodeSize: ArtworkDecodeSize(
                            width: geometry.size.width, height: geometry.size.height, scale: displayScale))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Design.posterCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Design.posterCornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                if watched { WatchedBadge().padding(8) }
            }
            .frame(width: width, alignment: .topLeading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(
                [item.releaseInfo ?? item.typeLabel, watched ? "Watched" : nil]
                    .compactMap { $0 }.joined(separator: ", "))
    }
}

struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white).frame(width: 28, height: 28)
            .background(.black.opacity(0.25), in: Circle())
            .glassEffect(.regular, in: .circle)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct MediaGrid: View {
    let items: [MediaItem]
    var onNearEnd: (() -> Void)? = nil
    var onSelect: ((MediaItem) -> Void)? = nil
    @State private var prefetch = ArtworkPrefetchState()
    @Environment(\.displayScale) private var displayScale
    @State private var availableWidth: CGFloat = 0

    private var decodeSize: ArtworkDecodeSize? {
        guard availableWidth > 0 else { return nil }
        let count = max(
            1, floor((availableWidth + Design.posterSpacing) / (Design.posterWidth + Design.posterSpacing)))
        let width = min(140, (availableWidth - Design.posterSpacing * (count - 1)) / count)
        return ArtworkDecodeSize(width: width, height: width * 1.5, scale: displayScale)
    }

    private var prefetchURLs: [URL] { prefetch.urls(items) }

    var body: some View {
        LazyVGrid(columns: Design.columns, alignment: .leading, spacing: 16) {
            ForEach(Array(items.enumerated()), id: \.element.key) { index, item in
                Group {
                    if let onSelect {
                        Button {
                            onSelect(item)
                        } label: {
                            PosterCard(item: item)
                        }
                    } else {
                        NavigationLink {
                            DetailView(item: item)
                        } label: {
                            PosterCard(item: item)
                        }
                    }
                }.buttonStyle(.plain)
                    .modifier(MediaContextMenu(item: item))
                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                        prefetch.visibility(visible, key: item.key, items: items)
                    }
                    .onAppear { if index >= items.count - 6 { onNearEnd?() } }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
        .prefetchArtwork(decodeSize == nil ? [] : prefetchURLs, size: decodeSize)
        .onDisappear { prefetch.reset() }
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
