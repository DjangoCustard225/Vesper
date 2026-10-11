import SwiftUI
import VesperCore

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @State private var filter = "all"
    @State private var prefetch = PosterPrefetchState()
    private var items: [MediaItem] { store.library.items.filter { filter == "all" || $0.type == filter } }
    private var prefetchURLs: [URL] { prefetch.urls(items) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.library.items.isEmpty {
                    ContentUnavailableView("Make it a movie night", systemImage: "bookmark", description: Text("Save a movie or series from its detail page. Your watchlist stays here on this device."))
                        .padding(.top, 70)
                } else {
                    Picker("Content", selection: $filter) { Text("All").tag("all"); Text("Movies").tag("movie"); Text("Series").tag("series") }.pickerStyle(.segmented)
                    if items.isEmpty { ContentUnavailableView("Nothing saved here yet", systemImage: "bookmark") }
                    LazyVGrid(columns: Design.columns, alignment: .leading, spacing: 24) {
                        ForEach(items, id: \.key) { item in
                            NavigationLink { DetailView(item: item) } label: { PosterCard(item: item) }.buttonStyle(.plain)
                                .onScrollVisibilityChange(threshold: 0.01) { visible in
                                    prefetch.visibility(visible, key: item.key, items: items)
                                }
                                .contextMenu { Button("Remove from library", systemImage: "bookmark.slash", role: .destructive) { store.toggleLibrary(item) } }
                        }
                    }
                }
            }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.appBackground().navigationTitle("Library")
            .task(id: prefetchURLs) { await ArtworkPipeline.shared.prefetch(prefetchURLs) }
            .onDisappear { prefetch.reset() }
    }
}
