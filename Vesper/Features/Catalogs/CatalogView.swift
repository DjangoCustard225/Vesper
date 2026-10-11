import SwiftUI
import VesperCore

struct CatalogView: View {
    @Environment(AppStore.self) private var store
    let feed: CatalogFeed
    @State private var genre = ""
    @State private var model = CatalogController()
    init(feed: CatalogFeed) {
        self.feed = feed
        _genre = State(initialValue: feed.catalog.defaultExtras["genre"] ?? "")
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                MediaGrid(items: model.items, onNearEnd: requestNextPage)
                if model.loading { ProgressView().padding() }
                if let error = model.error { ErrorNotice(message: error) { Task { await model.loadMore() } } }
                if !model.loading && model.items.isEmpty && model.error == nil { ContentUnavailableView("No titles found", systemImage: "film", description: Text("Try a different filter.")) }
                if model.hasMore && !model.loading && !model.items.isEmpty && model.error == nil { AutoPaginationTrigger(load: requestNextPage).id(model.pageRevision) }
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
            .task(id: genre + store.addonSignature + store.tmdbRevision.uuidString) {
                await model.load(store.addonSource(feed, genre: genre))
            }
            .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
            .onDisappear { model.cancel() }
    }
    private func requestNextPage() {
        guard model.hasMore, !model.loading, model.error == nil else { return }
        Task { await model.loadMore() }
    }
}
