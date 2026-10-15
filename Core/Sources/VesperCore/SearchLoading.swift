import Foundation
import Observation

public struct SearchAddonProvider: Sendable {
    public let name: String
    public let search: @Sendable (String) async throws -> [MediaItem]

    public init(name: String, search: @escaping @Sendable (String) async throws -> [MediaItem]) {
        self.name = name
        self.search = search
    }
}

public struct SearchProviders: Sendable {
    public let tmdb: (@MainActor @Sendable (String, Int) async throws -> TMDBPage)?
    public let addons: [SearchAddonProvider]

    public init(
        tmdb: (@MainActor @Sendable (String, Int) async throws -> TMDBPage)? = nil,
        addons: [SearchAddonProvider] = []
    ) {
        self.tmdb = tmdb
        self.addons = addons
    }
}

private enum SearchProviderResult: Sendable {
    case tmdb(TMDBPage?, String?)
    case addon(Int, [MediaItem], String?)
}

@MainActor @Observable
public final class SearchController {
    public private(set) var items: [MediaItem] = []
    public private(set) var loading = false
    public private(set) var searchingProviders = false
    public private(set) var failures: [String] = []
    public private(set) var page = 0
    public private(set) var hasMore = false
    public private(set) var loadingMore = false
    public private(set) var pageError: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var providers = SearchProviders()
    @ObservationIgnored private var tmdbItems: [MediaItem] = []
    @ObservationIgnored private var addonItems: [MediaItem] = []
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var paginationRequest: Task<Void, Never>?

    public init() {}

    public func cancel() {
        generation = UUID()
        request?.cancel()
        request = nil
        paginationRequest?.cancel()
        paginationRequest = nil
        loading = false
        searchingProviders = false
        loadingMore = false
    }

    public func search(
        _ term: String, using providers: SearchProviders,
        debounce: Duration = .milliseconds(300)
    ) async {
        cancel()
        let current = generation
        query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providers = providers
        items = []
        tmdbItems = []
        addonItems = []
        failures = []
        page = 0
        hasMore = false
        loadingMore = false
        pageError = nil
        guard !query.isEmpty else {
            loading = false
            searchingProviders = false
            return
        }
        loading = true
        searchingProviders = false
        let query = self.query
        let task = Task {
            await performSearch(query, using: providers, debounce: debounce, generation: current)
        }
        request = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == current { request = nil }
    }

    private func performSearch(
        _ query: String, using providers: SearchProviders,
        debounce: Duration, generation current: UUID
    ) async {
        do {
            try await Task.sleep(for: debounce)
            try Task.checkCancellation()
        } catch { return }
        guard generation == current else { return }
        searchingProviders = true
        var addonResults: [(Int, [MediaItem], String?)] = []
        var tmdbFailure: String?
        await withTaskGroup(of: SearchProviderResult.self) { group in
            if let tmdb = providers.tmdb {
                group.addTask {
                    do { return .tmdb(try await tmdb(query, 1), nil) } catch is CancellationError {
                        return .tmdb(nil, nil)
                    } catch { return .tmdb(nil, error.localizedDescription) }
                }
            }
            for (index, provider) in providers.addons.enumerated() {
                group.addTask {
                    do {
                        return .addon(index, try await provider.search(query), nil)
                    } catch is CancellationError { return .addon(index, [], nil) } catch {
                        return .addon(index, [], provider.name + ": " + error.localizedDescription)
                    }
                }
            }
            for await result in group {
                guard generation == current, !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                switch result {
                case .tmdb(let response, let failure):
                    tmdbItems = response?.items ?? []
                    tmdbFailure = failure
                    page = response?.page ?? 0
                    hasMore = response?.hasMore ?? false
                case .addon(let index, let titles, let failure):
                    addonResults.append((index, titles, failure))
                    addonItems = addonResults.sorted { $0.0 < $1.0 }.flatMap(\.1)
                }
                items = unique(tmdbItems + addonItems)
                failures = Array(Set(addonResults.compactMap(\.2))).sorted()
                if let tmdbFailure { failures.insert(tmdbFailure, at: 0) }
                if !items.isEmpty { loading = false }
            }
        }
        guard generation == current, !Task.isCancelled else { return }
        if providers.tmdb == nil && providers.addons.isEmpty {
            failures = ["Connect TMDB in Settings to search movies and series."]
        }
        loading = false
        searchingProviders = false
    }

    public func loadMore() async {
        guard !loadingMore, !loading, hasMore, let tmdb = providers.tmdb else { return }
        let current = generation, term = query
        loadingMore = true
        pageError = nil
        let task = Task { await performLoadMore(term, tmdb: tmdb, generation: current) }
        paginationRequest = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == current {
            paginationRequest = nil
            loadingMore = false
        }
    }

    private func performLoadMore(
        _ term: String, tmdb: @MainActor @Sendable (String, Int) async throws -> TMDBPage,
        generation current: UUID
    ) async {
        defer { if generation == current { loadingMore = false } }
        do {
            let next = try await tmdb(term, page + 1)
            guard !Task.isCancelled, generation == current else { return }
            let previous = unique(tmdbItems)
            tmdbItems = unique(previous + next.items)
            page = next.page
            hasMore = next.hasMore && (tmdbItems.count > previous.count || next.items.isEmpty)
            items = unique(tmdbItems + addonItems)
        } catch is CancellationError { return } catch {
            if generation == current { pageError = error.localizedDescription }
        }
    }

    private func unique(_ items: [MediaItem]) -> [MediaItem] {
        var keys = Set<String>()
        return items.filter { keys.insert($0.key).inserted }
    }
}
