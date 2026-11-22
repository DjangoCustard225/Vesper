import SwiftUI
import VesperCore

struct CatalogView: View {
    @Environment(AppStore.self) private var store
    let feed: CatalogFeed
    @State private var selections: [String: String]?
    @State private var model = CatalogController()
    @State private var loadedRequest: ContentRequestID<[String: String]>?

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

    private var requestID: ContentRequestID<[String: String]> {
        ContentRequestID(input: extras, context: store.contentContext)
    }

    var body: some View {
        ScrollView {
            CatalogContentView(
                model: model, emptyTitle: "No titles found", emptyDescription: "Try a different filter.")
        }
        // A new request starts a fresh scroll view at the top. Tracking the scroll position with a
        // binding instead would re-evaluate this page, and diff the whole grid, as rows scroll by.
        .id(loadedRequest).appBackground().navigationTitle(
            store.catalogTitle(.addon(currentFeed))
        )
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
        .task(id: requestID) {
            let request = requestID
            if loadedRequest == request {
                if model.items.isEmpty, model.error == nil { await model.loadMore() }
                return
            }
            loadedRequest = request
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
