import SwiftUI
import VesperCore

struct CombinedCatalogView: View {
    @Environment(AppStore.self) private var store
    let group: CombinedCatalog
    @State private var model = CombinedCatalogController()
    @State private var loadedRequest: ContentRequestID<[String]>?

    private var current: CombinedCatalog? { store.catalogPreferences.groups.first { $0.id == group.id } }
    private var sources: [CombinedCatalogSource] { current.map(store.combinedSources) ?? [] }

    private var requestID: ContentRequestID<[String]> {
        ContentRequestID(
            input: sources.map { $0.id + ":" + ($0.source.initialCacheID ?? "") },
            context: store.contentContext)
    }

    var body: some View {
        ScrollView {
            if sources.isEmpty {
                ContentUnavailableView {
                    Label("No available catalogs", systemImage: "rectangle.stack")
                } actions: {
                    if let current {
                        NavigationLink("Edit Catalog") { CombinedCatalogEditor(group: current) }
                    }
                }.padding(.top, 40)
            } else {
                CatalogContentView(model: model, emptyTitle: "No titles available")
            }
        }
        // A new request starts a fresh scroll view at the top. Tracking the scroll position with a
        // binding instead would re-evaluate this page, and diff the whole grid, as rows scroll by.
        .id(loadedRequest)
        .appBackground().navigationTitle(current?.name ?? group.name).toolbar(.visible, for: .navigationBar)
        .task(id: requestID) {
            let request = requestID
            if loadedRequest == request {
                if model.items.isEmpty, model.error == nil { await model.loadMore() }
                return
            }
            loadedRequest = request
            await model.load(sources)
        }
        .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
        .onDisappear { model.cancel() }
    }
}
