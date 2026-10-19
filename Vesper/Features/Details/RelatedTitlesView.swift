import SwiftUI
import VesperCore

struct RelatedTitlesView: View {
    @Environment(AppStore.self) private var store
    let details: MetadataEnrichment
    @State private var model = CatalogController()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.items.isEmpty || model.loading || model.error != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Related").font(.title2.bold()).padding(.horizontal, 24)
                    if !model.items.isEmpty {
                        PosterShelf(items: Array(model.items.prefix(20)), horizontalPadding: 24)
                    }
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error = model.error {
                        ErrorNotice(message: error) {
                            Task { await model.load(store.relatedSource(details)) }
                        }.padding(.horizontal, 24)
                    }
                }.padding(.horizontal, -24)
            }
        }
        .task(id: "\(details.mediaType):\(details.tmdbID ?? 0):\(store.tmdbRevision)") {
            await model.load(store.relatedSource(details))
        }
        .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
        .onDisappear { model.cancel() }
    }
}
