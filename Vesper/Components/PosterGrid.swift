import SwiftUI
import VesperCore

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
    @State private var prefetch = PosterPrefetchState()

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
        .prefetchArtwork(prefetchURLs)
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
