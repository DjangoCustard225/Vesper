import SwiftUI
import VesperCore

struct RelatedTitlesView: View {
    @Environment(AppStore.self) private var store
    let details: MetadataEnrichment
    @State private var model = CatalogController()
    @State private var loadedRequest: String?

    private var requestKey: String {
        "\(details.mediaType):\(details.tmdbID ?? 0):\(store.tmdbRevision)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.items.isEmpty || model.loading || model.error != nil {
                VStack(alignment: .leading, spacing: 12) {
                    NavigationLink {
                        ScrollView {
                            CatalogContentView(model: model, emptyTitle: "No related titles")
                        }
                        .appBackground().navigationTitle("Related").toolbar(.visible, for: .navigationBar)
                    } label: {
                        CatalogHeading(title: "Related")
                    }
                    .buttonStyle(.plain).padding(.horizontal, 24).accessibilityHint(
                        "Shows all related titles")
                    if !model.items.isEmpty {
                        PosterShelf(items: Array(model.items.prefix(20)), horizontalPadding: 24)
                    }
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error = model.error {
                        ErrorNotice(message: error) {
                            Task { await model.loadMore() }
                        }.padding(.horizontal, 24)
                    }
                }.padding(.horizontal, -24)
            }
        }
        .task(id: requestKey) {
            if loadedRequest == requestKey {
                if model.items.isEmpty, model.error == nil { await model.loadMore() }
                return
            }
            loadedRequest = requestKey
            await model.load(store.relatedSource(details))
        }
        .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
        .onDisappear { model.cancel() }
    }
}
