import SwiftUI
import VesperCore

@MainActor @Observable
final class PosterPrefetchState {
    private var visibleKeys: Set<String> = []
    private var leadingIndex: Int?
    private var forward = true
    func visibility(_ visible: Bool, key: String, items: [MediaItem]) {
        if visible { visibleKeys.insert(key) } else { visibleKeys.remove(key) }
        let keys = Set(items.map(\.key))
        visibleKeys.formIntersection(keys)
        if let next = items.firstIndex(where: { visibleKeys.contains($0.key) }) {
            if let leadingIndex, next != leadingIndex { forward = next > leadingIndex }
            leadingIndex = next
        }
    }
    func urls(_ items: [MediaItem]) -> [URL] {
        ArtworkPrefetchWindow.urls(items: items, visibleKeys: visibleKeys, forward: forward)
    }
    func reset() { visibleKeys = []; leadingIndex = nil; forward = true }
}

struct PosterShelf: View {
    let items: [MediaItem]
    var horizontalPadding: CGFloat = 20
    @State private var prefetch = PosterPrefetchState()
    @State private var visible = false
    private var urls: [URL] { visible ? prefetch.urls(items) : [] }
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Design.posterSpacing) {
                ForEach(items, id: \.key) { item in
                    NavigationLink { DetailView(item: item) } label: {
                        PosterCard(item: item, width: Design.posterWidth)
                    }.buttonStyle(.plain)
                        .modifier(MediaContextMenu(item: item))
                        .onScrollVisibilityChange(threshold: 0.01) { active in
                            prefetch.visibility(active, key: item.key, items: items)
                        }
                }
            }.padding(.horizontal, horizontalPadding)
        }.scrollIndicators(.hidden).appScrollEdges()
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .prefetchArtwork(urls)
            .onDisappear { visible = false; prefetch.reset() }
    }
}
