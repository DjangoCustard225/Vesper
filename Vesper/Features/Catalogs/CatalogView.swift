import SwiftUI
import VesperCore

struct CatalogView: View {
    @Environment(AppStore.self) private var store
    let feed: CatalogFeed
    @State private var items: [MediaItem] = []
    @State private var genre = ""
    @State private var loading = false
    @State private var error: String?
    @State private var canLoadMore = true
    @State private var offset = 0
    @State private var generation = UUID()
    init(feed: CatalogFeed) {
        self.feed = feed
        _genre = State(initialValue: feed.catalog.defaultExtras["genre"] ?? "")
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                MediaGrid(items: items, onNearEnd: requestNextPage)
                if loading { ProgressView().padding() }
                if let error { ErrorNotice(message: error) { Task { await load(reset: items.isEmpty) } } }
                if !loading && items.isEmpty && error == nil { ContentUnavailableView("No titles found", systemImage: "film", description: Text("Try a different filter.")) }
                if canLoadMore && !loading && !items.isEmpty && error == nil { AutoPaginationTrigger(load: requestNextPage).id(offset) }
            }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.appBackground().navigationTitle(feed.catalog.title).toolbar(.visible, for: .navigationBar)
            .toolbar {
                if !feed.catalog.genres.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker(feed.catalog.genreLabel, selection: $genre) {
                                if !feed.catalog.requiredExtras.contains("genre") { Text("All \(feed.catalog.genreLabel.lowercased())s").tag("") }
                                ForEach(feed.catalog.genres, id: \.self) { Text($0).tag($0) }
                            }
                        } label: { Label(genre.isEmpty ? feed.catalog.genreLabel : genre, systemImage: "line.3.horizontal.decrease") }
                    }
                }
            }
            .task(id: genre) { await load(reset: true) }
    }
    private func requestNextPage() {
        guard canLoadMore, !loading, error == nil, !items.isEmpty else { return }
        Task { await load(reset: false) }
    }
    private func load(reset: Bool) async {
        if reset { generation = UUID(); items = []; offset = 0; canLoadMore = true }
        else if loading || !canLoadMore { return }
        let current = generation
        loading = true; error = nil
        defer { if current == generation { loading = false } }
        var extras = feed.catalog.defaultExtras
        if !genre.isEmpty { extras["genre"] = genre }
        if offset > 0 { extras["skip"] = String(offset) }
        do {
            let next = try await store.client.catalog(feed.addon, feed.catalog, extras: extras)
            try Task.checkCancellation()
            guard current == generation else { return }
            let merged = CatalogPagination(existing: items, incoming: next, providerHasMore: feed.catalog.supports("skip"))
            items = merged.items
            offset += next.count
            canLoadMore = merged.hasMore
        } catch is CancellationError { }
        catch { if current == generation { self.error = error.localizedDescription } }
    }
}
