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
            }
            if feed.items.isEmpty && feed.error == nil {
                if store.isLoading { ProgressView().padding(.horizontal, 20) }
                else { Text("No titles available yet.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20) }
            } else if !feed.items.isEmpty {
                PosterShelf(items: feed.items)
            }
        }
    }
}

struct TMDBCatalogView: View {
    @Environment(AppStore.self) private var store
    let catalog: TMDBCatalog
    @State private var model = CatalogController()
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                MediaGrid(items: model.items, onNearEnd: requestNextPage)
                if model.loading { ProgressView("Loading titles…").padding(24) }
                if let error = model.error { ErrorNotice(message: error) { Task { await model.loadMore() } } }
                if !model.loading && model.items.isEmpty && model.error == nil { ContentUnavailableView("No titles available", systemImage: "film") }
                if model.hasMore && !model.loading && model.error == nil && !model.items.isEmpty { AutoPaginationTrigger(load: requestNextPage).id(model.pageRevision) }
            }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.appBackground().navigationTitle(catalog.title).toolbar(.visible, for: .navigationBar)
            .task(id: store.tmdbRevision) { await model.load(store.tmdbSource(catalog)) }
            .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
            .onDisappear { model.cancel() }
    }
    private func requestNextPage() {
        guard model.hasMore, !model.loading, model.error == nil else { return }
        Task { await model.loadMore() }
    }
}
