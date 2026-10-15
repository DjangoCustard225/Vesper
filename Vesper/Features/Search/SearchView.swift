import SwiftUI
import VesperCore

struct SearchView: View {
    let onSelect: (MediaItem) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool
    @State private var didFocusSearch = false
    @State private var query = ""
    @State private var model = SearchController()
    @State private var filter = "all"

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchKey: ContentRequestID<String> {
        ContentRequestID(input: trimmed, context: store.contentContext)
    }

    private var filtered: [MediaItem] { model.items.filter { filter == "all" || $0.type == filter } }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                searchHeader
                searchResults
            }
        }.appScrollEdges().scrollDismissesKeyboard(.interactively)
            .appBackground().navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close search", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            .task {
                guard !didFocusSearch else { return }
                didFocusSearch = true
                await Task.yield()
                guard !Task.isCancelled else { return }
                queryFocused = true
            }
            .task(id: searchKey) {
                await model.search(trimmed, using: providers(for: trimmed))
            }
            .onDisappear { model.cancel() }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Search").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 2)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search for movies and shows", text: $query)
                    .textFieldStyle(.plain).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).focused($queryFocused)
                    .onSubmit { queryFocused = false }
            }.padding(.horizontal, 16).padding(.vertical, 14)
                .glassEffect(.regular, in: Capsule()).padding(.horizontal, 20).padding(.vertical, 10)
        }.frame(maxWidth: 1100).frame(maxWidth: .infinity)
    }

    private var searchResults: some View {
        VStack(spacing: 24) {
            if !trimmed.isEmpty {
                MediaTypePicker(selection: $filter)
                if model.loading || (filtered.isEmpty && model.searchingProviders) {
                    ProgressView("Searching…").padding(.vertical, 40)
                }
                if !filtered.isEmpty {
                    MediaGrid(items: filtered, onNearEnd: requestNextPage, onSelect: onSelect)
                }
                if !model.loading && !model.searchingProviders && filtered.isEmpty && !model.hasMore {
                    ContentUnavailableView.search(text: trimmed)
                }
                if model.loadingMore { ProgressView() }
                if model.hasMore && !model.loading && !model.loadingMore && model.pageError == nil {
                    AutoPaginationTrigger(load: requestNextPage).id("\(searchKey):\(model.page):\(filter)")
                }
                if let pageError = model.pageError {
                    ErrorNotice(message: pageError) { Task { await model.loadMore() } }
                }
                ForEach(model.failures, id: \.self) {
                    ErrorNotice(message: $0) {
                        Task { await model.search(trimmed, using: providers(for: trimmed), debounce: .zero) }
                    }
                }
            }
        }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
    }

    private func providers(for term: String) -> SearchProviders {
        let catalogs = store.enabledAddons.flatMap { addon in
            addon.manifest.catalogs.filter {
                $0.supports("search")
                    && $0.canRequest(with: $0.defaultExtras.merging(["search": term]) { _, new in new })
            }.map { (addon, $0) }
        }
        let tmdb: (@MainActor @Sendable (String, Int) async throws -> TMDBPage)?
        if store.tmdbCredential != nil {
            tmdb = { [store] query, page in try await store.tmdbSearch(query, page: page) }
        } else {
            tmdb = nil
        }
        let addons = catalogs.map { addon, catalog in
            SearchAddonProvider(name: addon.manifest.name) { [client = store.client] query in
                try await client.catalog(
                    addon, catalog, extras: catalog.defaultExtras.merging(["search": query]) { _, new in new }
                )
            }
        }
        return SearchProviders(tmdb: tmdb, addons: addons)
    }

    private func requestNextPage() {
        guard model.hasMore, !model.loading, !model.loadingMore, model.pageError == nil else { return }
        Task { await model.loadMore() }
    }
}
