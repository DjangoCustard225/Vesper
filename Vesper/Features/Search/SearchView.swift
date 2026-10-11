import SwiftUI
import VesperCore

struct SearchView: View {
    let onSelect: (MediaItem) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool
    @State private var didFocusSearch = false
    @State private var completedSearchKey: String?
    @State private var query = ""
    @State private var model = SearchController()
    @State private var filter = "all"
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchKey: String { trimmed + store.addonSignature + store.tmdbRevision.uuidString }
    private var filtered: [MediaItem] { model.items.filter { filter == "all" || $0.type == filter } }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if !trimmed.isEmpty {
                    Picker("Content type", selection: $filter) { Text("All").tag("all"); Text("Movies").tag("movie"); Text("Series").tag("series") }.pickerStyle(.segmented)
                    if model.loading || (filtered.isEmpty && model.searchingProviders) { ProgressView("Searching…").padding(.vertical, 40) }
                    if !filtered.isEmpty {
                        MediaGrid(items: filtered, onNearEnd: requestNextPage, onSelect: onSelect)
                    }
                    if !model.loading && !model.searchingProviders && filtered.isEmpty && !model.hasMore {
                        if store.tmdbCredential == nil && store.searchSources(trimmed).isEmpty {
                            ErrorNotice(message: "Connect TMDB in Settings to search movies and series.")
                        } else { ContentUnavailableView.search(text: trimmed) }
                    }
                    if model.loadingMore { ProgressView() }
                    if model.hasMore && !model.loading && !model.loadingMore && model.pageError == nil {
                        AutoPaginationTrigger(load: requestNextPage).id("\(model.revision):\(model.pageRevision):\(filter)")
                    }
                    if let pageError = model.pageError { ErrorNotice(message: pageError) { Task { await model.loadMore() } } }
                    ForEach(model.failures, id: \.self) { ErrorNotice(message: $0) { Task { await search() } } }
                }
            }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.appBackground().navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close search", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search for movies and shows", text: $query)
                        .textFieldStyle(.plain).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search).focused($queryFocused)
                        .onSubmit { queryFocused = false }
                }.padding(.horizontal, 16).padding(.vertical, 14)
                    .glassEffect(.regular, in: Capsule()).padding(.horizontal, 20).padding(.vertical, 10)
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                guard !didFocusSearch else { return }
                didFocusSearch = true
                await Task.yield()
                guard !Task.isCancelled else { return }
                queryFocused = true
            }
            .task(id: searchKey) {
                let key = searchKey
                guard completedSearchKey != key else { return }
                completedSearchKey = nil
                await search(debounce: .milliseconds(300))
                if !Task.isCancelled && searchKey == key { completedSearchKey = key }
            }
            .onChange(of: store.cacheChanges) { _, change in model.refresh(cacheIDs: change.ids) }
            .onDisappear { model.cancel() }
    }
    private func search(debounce: Duration = .zero) async {
        let sources = trimmed.isEmpty ? [] : store.searchSources(trimmed)
        await model.search(sources: sources, primaryID: "tmdb-search", debounce: debounce) { items in
            await store.identifiedItems(items)
        }
    }
    private func requestNextPage() {
        guard model.hasMore, !model.loading, !model.loadingMore, model.pageError == nil else { return }
        Task { await model.loadMore() }
    }
}
