import SwiftUI
import VesperCore

struct RelatedTitlesView: View {
    @Environment(AppStore.self) private var store
    let details: TMDBEnrichment
    @State private var items: [MediaItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !items.isEmpty || loading || error != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Related").font(.title2.bold()).padding(.horizontal, 24)
                    if !items.isEmpty {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: Design.posterSpacing) {
                                ForEach(items, id: \.key) { item in
                                    NavigationLink { DetailView(item: item) } label: {
                                        PosterCard(item: item, width: Design.posterWidth)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.horizontal, 24)
                        }.scrollIndicators(.hidden).appScrollEdges()
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error {
                        ErrorNotice(message: error) { Task { await load() } }.padding(.horizontal, 24)
                    }
                }.padding(.horizontal, -24)
            }
        }
        .task(id: "\(details.mediaType):\(details.id):\(store.tmdbRevision)") { await load() }
        .onDisappear { requestID = UUID() }
    }

    private func load() async {
        let request = UUID(); requestID = request
        loading = true; error = nil; items = []
        defer { if requestID == request { loading = false } }
        do {
            let result = try await store.recommendations(for: details)
            guard !Task.isCancelled, requestID == request else { return }
            items = Array(result.items.prefix(20))
        } catch is CancellationError { }
        catch { if !Task.isCancelled && requestID == request { self.error = error.localizedDescription } }
    }
}
