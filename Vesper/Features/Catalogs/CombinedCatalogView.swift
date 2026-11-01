import SwiftUI
import VesperCore

struct CombinedCatalogView: View {
    @Environment(AppStore.self) private var store
    let group: CombinedCatalog
    @State private var model = CombinedCatalogController()

    private var current: CombinedCatalog? { store.catalogPreferences.groups.first { $0.id == group.id } }
    private var sources: [CombinedCatalogSource] { current.map(store.combinedSources) ?? [] }

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
        .appBackground().navigationTitle(current?.name ?? group.name).toolbar(.visible, for: .navigationBar)
        .task(
            id: ContentRequestID(
                input: sources.map { $0.id + ":" + ($0.source.initialCacheID ?? "") },
                context: store.contentContext)
        ) {
            await model.load(sources)
        }
        .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
        .onDisappear { model.cancel() }
    }
}
