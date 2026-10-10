import SwiftUI
import VesperCore

struct TMDBShelf: View {
    @Environment(AppStore.self) private var store
    let feed: TMDBFeed
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink { TMDBCatalogView(catalog: feed.catalog) } label: {
                CatalogHeading(title: feed.catalog.title)
            }.buttonStyle(.plain).accessibilityLabel("See all \(feed.catalog.title)").padding(.horizontal, 20)
            if let error = feed.error {
                ErrorNotice(message: error) { Task { await store.refresh() } }.padding(.horizontal, 20)
            } else if feed.items.isEmpty {
                if store.isLoading { ProgressView().padding(.horizontal, 20) }
                else { Text("No titles available yet.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20) }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Design.posterSpacing) {
                        ForEach(feed.items, id: \.key) { item in
                            NavigationLink { DetailView(item: item) } label: { PosterCard(item: item, width: Design.posterWidth) }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 20)
                }.scrollIndicators(.hidden).appScrollEdges()
            }
        }
    }
}

struct TMDBCatalogView: View {
    @Environment(AppStore.self) private var store
    let catalog: TMDBCatalog
    @State private var items: [MediaItem] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                MediaGrid(items: items, onNearEnd: requestNextPage)
                if loading { ProgressView("Loading titles…").padding(24) }
                if let error { ErrorNotice(message: error) { Task { await load(reset: page == 0) } } }
                if !loading && items.isEmpty && error == nil { ContentUnavailableView("No titles available", systemImage: "film") }
                if hasMore && !loading && error == nil && !items.isEmpty { AutoPaginationTrigger(load: requestNextPage).id(page) }
            }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.appBackground().navigationTitle(catalog.title).toolbar(.visible, for: .navigationBar)
            .task(id: store.tmdbRevision) { await load(reset: true) }
    }
    private func requestNextPage() {
        guard hasMore, !loading, error == nil, !items.isEmpty else { return }
        Task { await load(reset: false) }
    }
    private func load(reset: Bool) async {
        if reset { generation = UUID(); items = []; page = 0; hasMore = true }
        else if loading || !hasMore { return }
        let current = generation
        loading = true; error = nil
        defer { if generation == current { loading = false } }
        do {
            let next = try await store.tmdbCatalog(catalog, page: page + 1)
            guard !Task.isCancelled, generation == current else { return }
            let merged = CatalogPagination(existing: items, incoming: next.items, providerHasMore: next.hasMore)
            items = merged.items; page = next.page; hasMore = merged.hasMore
        } catch is CancellationError { return }
        catch { if generation == current { self.error = error.localizedDescription } }
    }
}
