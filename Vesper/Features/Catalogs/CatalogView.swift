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
            CatalogContentView(
                model: model, emptyTitle: "No titles found", emptyDescription: "Try a different filter.")
        }.appBackground().navigationTitle(feed.catalog.title).toolbar(.visible, for: .navigationBar)
            .toolbar {
                if !feed.catalog.genres.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker(feed.catalog.genreLabel, selection: $genre) {
                                if !feed.catalog.requiredExtras.contains("genre") {
                                    Text("All \(feed.catalog.genreLabel.lowercased())s").tag("")
                                }
                                ForEach(feed.catalog.genres, id: \.self) { Text($0).tag($0) }
                            }
                        } label: {
                            Label(
                                genre.isEmpty ? feed.catalog.genreLabel : genre,
                                systemImage: "line.3.horizontal.decrease")
                        }
                    }
                }
            }
            .task(id: ContentRequestID(input: genre, context: store.contentContext)) {
                await model.load(store.addonSource(feed, genre: genre))
            }
            .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
            .onDisappear { model.cancel() }
    }
}
