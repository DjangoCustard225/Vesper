import SwiftUI
import VesperCore

struct CatalogView: View {
    @Environment(AppStore.self) private var store
    let feed: CatalogFeed
    @State private var selections: [String: String]?
    @State private var model = CatalogController()

    private var currentFeed: CatalogFeed {
        if let catalog = store.catalogs.first(where: { $0.id == HomeCatalog.addon(feed).id }),
            case .addon(let current) = catalog
        {
            return current
        }
        return feed
    }

    private var extras: [String: String] {
        currentFeed.catalog.effectiveExtras(selections ?? store.catalogDefaults(currentFeed))
    }

    var body: some View {
        ScrollView {
            CatalogContentView(
                model: model, emptyTitle: "No titles found", emptyDescription: "Try a different filter.")
        }.appBackground().navigationTitle(store.catalogTitle(.addon(currentFeed)))
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if !currentFeed.catalog.filters.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            CatalogFilterPickers(
                                catalog: currentFeed.catalog,
                                selections: Binding(get: { extras }, set: { selections = $0 }))
                        } label: {
                            Label(filterTitle, systemImage: "line.3.horizontal.decrease")
                        }
                    }
                }
            }
            .task(id: ContentRequestID(input: extras, context: store.contentContext)) {
                await model.load(store.addonSource(currentFeed, extras: extras))
            }
            .onChange(of: store.catalogDefaults(currentFeed)) { _, _ in selections = nil }
            .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
            .onDisappear { model.cancel() }
    }

    private var filterTitle: String {
        if currentFeed.catalog.filters.count == 1, let filter = currentFeed.catalog.filters.first {
            return extras[filter.id] ?? filter.title
        }
        return "Filters"
    }
}
