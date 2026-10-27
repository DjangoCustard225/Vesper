import SwiftUI
import VesperCore

@MainActor @Observable
final class ArtworkPrefetchState {
    private var visibleIDs: Set<String> = []
    private var leadingIndex: Int?
    private var forward = true

    func visibility(_ visible: Bool, key: String, items: [MediaItem]) {
        update(visible, id: key, orderedIDs: items.map(\.key))
    }

    func visibility(_ visible: Bool, id: String, rows: [ArtworkPrefetchWindow.Row]) {
        update(visible, id: id, orderedIDs: rows.map(\.id))
    }

    func urls(_ items: [MediaItem]) -> [URL] {
        ArtworkPrefetchWindow.urls(items: items, visibleKeys: visibleIDs, forward: forward)
    }

    func urls(rows: [ArtworkPrefetchWindow.Row], width: CGFloat) -> [URL] {
        let count = max(1, Int(ceil(max(0, width - 40) / (Design.posterWidth + Design.posterSpacing))))
        return ArtworkPrefetchWindow.urls(
            rows: rows, visibleRows: visibleIDs, forward: forward, posterCount: count)
    }

    func reset() {
        visibleIDs = []
        leadingIndex = nil
        forward = true
    }

    private func update(_ visible: Bool, id: String, orderedIDs: [String]) {
        if visible { visibleIDs.insert(id) } else { visibleIDs.remove(id) }
        visibleIDs.formIntersection(orderedIDs)
        if let next = orderedIDs.firstIndex(where: { visibleIDs.contains($0) }) {
            if let leadingIndex, next != leadingIndex { forward = next > leadingIndex }
            leadingIndex = next
        }
    }
}

struct PosterShelf: View {
    let items: [MediaItem]
    var horizontalPadding: CGFloat = 20
    @State private var prefetch = ArtworkPrefetchState()
    @State private var visible = false
    @Environment(\.displayScale) private var displayScale

    private var urls: [URL] { visible ? prefetch.urls(items) : [] }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Design.posterSpacing) {
                ForEach(items, id: \.key) { item in
                    NavigationLink {
                        DetailView(item: item)
                    } label: {
                        PosterCard(item: item, width: Design.posterWidth)
                    }.buttonStyle(.plain)
                        .modifier(MediaContextMenu(item: item))
                        .onScrollVisibilityChange(threshold: 0.01) { active in
                            prefetch.visibility(active, key: item.key, items: items)
                        }
                }
            }.padding(.horizontal, horizontalPadding)
        }.frame(height: Design.posterWidth * 1.5)
            .scrollIndicators(.hidden).appScrollEdges()
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .prefetchArtwork(
                urls,
                size: ArtworkDecodeSize(
                    width: Design.posterWidth, height: Design.posterWidth * 1.5, scale: displayScale)
            )
            .onDisappear {
                visible = false
                prefetch.reset()
            }
    }
}
