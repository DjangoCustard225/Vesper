import SwiftUI
import VesperCore

struct TMDBCatalogView: View {
    @Environment(AppStore.self) private var store
    let catalog: TMDBCatalog
    @State private var model = CatalogController()

    var body: some View {
        ScrollView {
            CatalogContentView(
                model: model, spacing: 20, loadingTitle: "Loading titles…", progressPadding: 24,
                emptyTitle: "No titles available")
        }.appBackground().navigationTitle(store.catalogTitle(.tmdb(catalog))).toolbar(
            .visible, for: .navigationBar
        )
        .task(id: store.tmdbRevision) { await model.load(store.tmdbSource(catalog)) }
        .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
        .onDisappear { model.cancel() }
    }
}
