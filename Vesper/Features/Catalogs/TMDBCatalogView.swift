import SwiftUI
import VesperCore

struct TMDBCatalogView: View {
    @Environment(AppStore.self) private var store
    let catalog: TMDBCatalog
    @State private var model = CatalogController()
    @State private var loadedRevision: UUID?

    var body: some View {
        ScrollView {
            CatalogContentView(
                model: model, spacing: 20, loadingTitle: "Loading titles…", progressPadding: 24,
                emptyTitle: "No titles available")
        }
        // A new request starts a fresh scroll view at the top. Tracking the scroll position with a
        // binding instead would re-evaluate this page, and diff the whole grid, as rows scroll by.
        .id(loadedRevision).appBackground().navigationTitle(
            store.catalogTitle(.tmdb(catalog))
        ).toolbar(
            .visible, for: .navigationBar
        )
        .task(id: store.tmdbRevision) {
            let revision = store.tmdbRevision
            if loadedRevision == revision {
                if model.items.isEmpty, model.error == nil { await model.loadMore() }
                return
            }
            loadedRevision = revision
            await model.load(store.tmdbSource(catalog))
        }
        .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
        .onDisappear { model.cancel() }
    }
}
