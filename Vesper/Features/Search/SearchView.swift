import SwiftUI
import VesperCore

private enum SearchProviderResult {
    case tmdb(TMDBPage?, String?)
    case addon(Int, [MediaItem], String?)
}

struct SearchView: View {
    let onSelect: (MediaItem) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool
    @State private var didFocusSearch = false
    @State private var completedSearchKey: String?
    @State private var query = ""
    @State private var items: [MediaItem] = []
    @State private var tmdbItems: [MediaItem] = []
    @State private var addonItems: [MediaItem] = []
    @State private var loading = false
    @State private var searchingProviders = false
    @State private var failures: [String] = []
    @State private var filter = "all"
    @State private var page = 0
    @State private var hasMore = false
    @State private var loadingMore = false
    @State private var generation = UUID()
    @State private var pageError: String?
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var searchKey: String { trimmed + store.addonSignature + store.tmdbRevision.uuidString }
    private var filtered: [MediaItem] { items.filter { filter == "all" || $0.type == filter } }
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
                let key = searchKey
                guard completedSearchKey != key else { return }
                completedSearchKey = nil
                generation = UUID(); items = []; tmdbItems = []; addonItems = []; failures = []
                page = 0; hasMore = false; loadingMore = false; searchingProviders = false; pageError = nil
                guard !trimmed.isEmpty else { loading = false; completedSearchKey = key; return }
                loading = true
                do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation() }
                catch { return }
                await search()
                if !Task.isCancelled && searchKey == key { completedSearchKey = key }
            }
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
                Picker("Content type", selection: $filter) {
                    Text("All").tag("all")
                    Text("Movies").tag("movie")
                    Text("Series").tag("series")
                }.pickerStyle(.segmented)
                if loading || (filtered.isEmpty && searchingProviders) {
                    ProgressView("Searching…").padding(.vertical, 40)
                }
                if !filtered.isEmpty {
                    MediaGrid(items: filtered, onNearEnd: requestNextPage, onSelect: onSelect)
                }
                if !loading && !searchingProviders && filtered.isEmpty && !hasMore {
                    ContentUnavailableView.search(text: trimmed)
                }
                if loadingMore { ProgressView() }
                if hasMore && !loading && !loadingMore && pageError == nil {
                    AutoPaginationTrigger(load: requestNextPage).id("\(generation):\(page):\(filter)")
                }
                if let pageError { ErrorNotice(message: pageError) { Task { await loadMore() } } }
                ForEach(failures, id: \.self) { ErrorNotice(message: $0) { Task { await search() } } }
            }
        }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity)
    }

    private func search() async {
        let term = trimmed
        guard !term.isEmpty else { return }
        let current = UUID(); generation = current
        loading = true; searchingProviders = true; loadingMore = false; hasMore = false; pageError = nil
        tmdbItems = []; addonItems = []; failures = []; page = 0
        let catalogs = store.enabledAddons.flatMap { addon in
            addon.manifest.catalogs.filter {
                $0.supports("search") && $0.canRequest(with: $0.defaultExtras.merging(["search": term]) { _, new in new })
            }.map { (addon, $0) }
        }
        var results: [(Int, [MediaItem], String?)] = []
        var tmdbFailure: String?
        await withTaskGroup(of: SearchProviderResult.self) { group in
            if store.tmdbCredential != nil {
                group.addTask {
                    let (page, failure) = await primarySearch(term)
                    return .tmdb(page, failure)
                }
            }
            for (index, pair) in catalogs.enumerated() {
                group.addTask { [client = store.client] in
                    do { return .addon(index, try await client.catalog(pair.0, pair.1, extras: pair.1.defaultExtras.merging(["search": term]) { _, new in new }), nil) }
                    catch is CancellationError { return .addon(index, [], nil) }
                    catch { return .addon(index, [], pair.0.manifest.name + ": " + error.localizedDescription) }
                }
            }
            for await result in group {
                guard term == trimmed, generation == current, !Task.isCancelled else { group.cancelAll(); return }
                switch result {
                case .tmdb(let response, let failure):
                    tmdbItems = response?.items ?? []; tmdbFailure = failure
                    page = response?.page ?? 0; hasMore = response?.hasMore ?? false
                case .addon(let index, let titles, let failure):
                    results.append((index, titles, failure))
                    addonItems = results.sorted { $0.0 < $1.0 }.flatMap(\.1)
                }
                items = AppStore.unique(tmdbItems + addonItems)
                failures = Array(Set(results.compactMap(\.2))).sorted()
                if let tmdbFailure { failures.insert(tmdbFailure, at: 0) }
                if !items.isEmpty { loading = false }
            }
        }
        guard term == trimmed, generation == current, !Task.isCancelled else { return }
        if catalogs.isEmpty && store.tmdbCredential == nil { failures = ["Connect TMDB in Settings to search movies and series."] }
        loading = false; searchingProviders = false
    }
    private func primarySearch(_ term: String) async -> (TMDBPage?, String?) {
        guard store.tmdbCredential != nil else { return (nil, nil) }
        do { return (try await store.tmdbSearch(term), nil) }
        catch is CancellationError { return (nil, nil) }
        catch { return (nil, error.localizedDescription) }
    }
    private func requestNextPage() {
        guard hasMore, !loading, !loadingMore, pageError == nil else { return }
        Task { await loadMore() }
    }
    private func loadMore() async {
        guard !loadingMore, !loading, hasMore else { return }
        let current = generation, term = trimmed
        loadingMore = true; pageError = nil
        defer { if generation == current { loadingMore = false } }
        do {
            let next = try await store.tmdbSearch(term, page: page + 1)
            guard !Task.isCancelled, generation == current, term == trimmed else { return }
            // A search page can contain only excluded people/adult results; advance to the next page.
            let previous = AppStore.unique(tmdbItems)
            tmdbItems = AppStore.unique(previous + next.items); page = next.page
            hasMore = next.hasMore && (tmdbItems.count > previous.count || next.items.isEmpty)
            items = AppStore.unique(tmdbItems + addonItems)
        } catch is CancellationError { return }
        catch { if generation == current { pageError = error.localizedDescription } }
    }
}
