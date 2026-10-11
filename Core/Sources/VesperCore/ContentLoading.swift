import Foundation
import Observation

public struct ContentPage: Sendable {
    public var items: [MediaItem]
    public let nextCursor: Int?
    public let cacheID: String?
    public init(items: [MediaItem], nextCursor: Int? = nil, cacheID: String? = nil) {
        self.items = items; self.nextCursor = nextCursor; self.cacheID = cacheID
    }
}

public struct ContentSource: Sendable {
    public let id: String
    public let title: String
    public let initialCursor: Int
    public let allowEmptyPages: Bool
    public let fetch: @MainActor @Sendable (Int) async throws -> ContentPage
    public init(id: String, title: String, initialCursor: Int = 1, allowEmptyPages: Bool = false,
                fetch: @escaping @MainActor @Sendable (Int) async throws -> ContentPage) {
        self.id = id; self.title = title; self.initialCursor = initialCursor
        self.allowEmptyPages = allowEmptyPages; self.fetch = fetch
    }
}

private struct LoadedPage {
    var value: ContentPage
    let revision = UUID()
}

@MainActor @Observable
public final class SearchController {
    public private(set) var items: [MediaItem] = []
    public private(set) var loading = false
    public private(set) var searchingProviders = false
    public private(set) var loadingMore = false
    public private(set) var failures: [String] = []
    public private(set) var pageError: String?
    public private(set) var hasMore = false
    public private(set) var revision = UUID()
    public private(set) var pageRevision = UUID()
    @ObservationIgnored private var sources: [ContentSource] = []
    @ObservationIgnored private var pages: [String: [Int: LoadedPage]] = [:]
    @ObservationIgnored private var errors: [String: String] = [:]
    @ObservationIgnored private var primaryID: String?
    @ObservationIgnored private var nextCursor: Int?
    @ObservationIgnored private var identify: @MainActor @Sendable ([MediaItem]) async -> [MediaItem] = { $0 }
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var pagination: Task<Void, Never>?
    @ObservationIgnored private var matching: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var pendingUpdates: Set<String> = []
    public init() {}

    public func cancel() {
        revision = UUID(); request?.cancel(); pagination?.cancel(); refreshing?.cancel()
        refreshing = nil
        matching.values.forEach { $0.cancel() }; matching = [:]; pendingUpdates = []
        loading = false; searchingProviders = false; loadingMore = false
    }
    public func search(sources: [ContentSource], primaryID: String?,
                       debounce: Duration = .zero,
                       identify: @escaping @MainActor @Sendable ([MediaItem]) async -> [MediaItem] = { $0 }) async {
        cancel()
        self.sources = sources; self.primaryID = primaryID; self.identify = identify
        pages = [:]; errors = [:]; items = []; failures = []; pageError = nil; hasMore = false; nextCursor = nil
        let current = revision
        loading = !sources.isEmpty; searchingProviders = !sources.isEmpty
        let task = Task {
            do { if !sources.isEmpty { try await Task.sleep(for: debounce) }; try Task.checkCancellation() }
            catch { return }
            await ConcurrentWork.run(sources, operation: { source in
                do { return Result<ContentPage, Error>.success(try await source.fetch(source.initialCursor)) }
                catch { return .failure(error) }
            }) { index, result in
                guard self.revision == current, !Task.isCancelled else { return }
                let source = sources[index]
                switch result {
                case .success(let page): self.accept(page, source: source, cursor: source.initialCursor, generation: current)
                case .failure(let error):
                    if !(error is CancellationError) { self.errors[source.id] = source.title + ": " + error.localizedDescription }
                }
                self.rebuild()
                if !self.items.isEmpty { self.loading = false }
            }
            guard self.revision == current, !Task.isCancelled else { return }
            self.loading = false; self.searchingProviders = false
            self.drainUpdates()
        }
        request = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if revision == current { loading = false; searchingProviders = false }
    }
    private func accept(_ page: ContentPage, source: ContentSource, cursor: Int, generation: UUID, replacing: Bool = false) {
        let previous = pages[source.id]?.sorted { $0.key < $1.key }.flatMap { $0.value.value.items } ?? []
        let stored = LoadedPage(value: page)
        pages[source.id, default: [:]][cursor] = stored
        errors[source.id] = nil
        if source.id == primaryID && !replacing {
            let merged = CatalogPagination(existing: previous, incoming: page.items, providerHasMore: page.nextCursor != nil,
                                           allowEmptyPages: source.allowEmptyPages)
            nextCursor = merged.hasMore ? page.nextCursor : nil; hasMore = nextCursor != nil
        }
        if !replacing { pageRevision = UUID() }
        let id = UUID(), resolver = identify
        matching[id] = Task {
            let values = await resolver(page.items)
            guard !Task.isCancelled, self.revision == generation,
                  self.pages[source.id]?[cursor]?.revision == stored.revision else { self.matching[id] = nil; return }
            self.pages[source.id]?[cursor]?.value.items = values
            self.rebuild(); self.matching[id] = nil
        }
        rebuild()
    }
    private func rebuild() {
        items = MediaIdentity.unique(sources.flatMap { source in
            pages[source.id]?.sorted { $0.key < $1.key }.flatMap { $0.value.value.items } ?? []
        })
        failures = sources.compactMap { errors[$0.id] }
    }
    public func loadMore() async {
        guard !loadingMore, let nextCursor, let source = sources.first(where: { $0.id == primaryID }) else { return }
        loadingMore = true; pageError = nil
        let current = revision
        let task = Task {
            do {
                let page = try await source.fetch(nextCursor)
                guard !Task.isCancelled, self.revision == current else { return }
                self.accept(page, source: source, cursor: nextCursor, generation: current)
            } catch is CancellationError { }
            catch { if self.revision == current { self.pageError = error.localizedDescription } }
            if self.revision == current { self.loadingMore = false; self.drainUpdates() }
        }
        pagination = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if revision == current { loadingMore = false }
    }
    public func refresh(cacheIDs: Set<String>) {
        let loaded = Set(pages.values.flatMap { $0.values.compactMap { $0.value.cacheID } })
        pendingUpdates.formUnion(searchingProviders || loadingMore ? cacheIDs : cacheIDs.intersection(loaded)); drainUpdates()
    }
    private func drainUpdates() {
        guard !searchingProviders, !loadingMore, refreshing == nil, !pendingUpdates.isEmpty else { return }
        let changed = pendingUpdates; pendingUpdates = []
        let current = revision
        let work = sources.flatMap { source in
            (pages[source.id] ?? [:]).compactMap { cursor, page -> (ContentSource, Int)? in
                page.value.cacheID.map { changed.contains($0) } == true ? (source, cursor) : nil
            }
        }
        refreshing = Task {
            for (source, cursor) in work {
                guard !Task.isCancelled, self.revision == current else { return }
                do {
                    let page = try await source.fetch(cursor)
                    guard !Task.isCancelled, self.revision == current else { return }
                    self.accept(page, source: source, cursor: cursor, generation: current, replacing: true)
                } catch { /* Background failures keep visible results. */ }
            }
            guard self.revision == current else { return }
            self.refreshing = nil; self.drainUpdates()
        }
    }
}

@MainActor @Observable
public final class CatalogController {
    public private(set) var items: [MediaItem] = []
    public private(set) var loading = false
    public private(set) var error: String?
    public private(set) var hasMore = false
    public private(set) var pageRevision = UUID()
    @ObservationIgnored private var source: ContentSource?
    @ObservationIgnored private var pages: [Int: ContentPage] = [:]
    @ObservationIgnored private var nextCursor: Int?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var pendingUpdates: Set<String> = []
    public init() {}
    public func cancel() {
        generation = UUID(); request?.cancel(); refreshing?.cancel(); refreshing = nil
        pendingUpdates = []; loading = false
    }
    public func load(_ source: ContentSource) async {
        cancel(); self.source = source; pages = [:]; items = []; error = nil
        nextCursor = source.initialCursor; hasMore = true
        await loadMore()
    }
    public func loadMore() async {
        guard !loading, let source, let cursor = nextCursor else { return }
        let current = generation
        loading = true; error = nil
        let task = Task {
            do {
                let page = try await source.fetch(cursor)
                guard !Task.isCancelled, self.generation == current else { return }
                let merged = CatalogPagination(existing: self.items, incoming: page.items,
                    providerHasMore: page.nextCursor != nil, allowEmptyPages: source.allowEmptyPages)
                self.pages[cursor] = page; self.rebuild()
                self.hasMore = merged.hasMore; self.nextCursor = merged.hasMore ? page.nextCursor : nil
                self.pageRevision = UUID()
            } catch is CancellationError { }
            catch { if self.generation == current { self.error = error.localizedDescription } }
            if self.generation == current { self.loading = false; self.drainUpdates() }
        }
        request = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == current { loading = false }
    }
    public func refresh(cacheIDs: Set<String>) {
        pendingUpdates.formUnion(loading ? cacheIDs : cacheIDs.intersection(Set(pages.values.compactMap(\.cacheID)))); drainUpdates()
    }
    private func rebuild() { items = MediaIdentity.unique(pages.sorted { $0.key < $1.key }.flatMap { $0.value.items }) }
    private func drainUpdates() {
        guard !loading, refreshing == nil, let source, !pendingUpdates.isEmpty else { return }
        let changed = pendingUpdates; pendingUpdates = []
        let current = generation
        let cursors = pages.filter { $0.value.cacheID.map { changed.contains($0) } == true }.keys.sorted()
        refreshing = Task {
            for cursor in cursors {
                guard !Task.isCancelled, self.generation == current else { return }
                do {
                    let page = try await source.fetch(cursor)
                    guard !Task.isCancelled, self.generation == current else { return }
                    self.pages[cursor] = page; self.rebuild()
                } catch { /* A failed revalidation must not hide loaded pages. */ }
            }
            guard self.generation == current else { return }
            self.refreshing = nil; self.drainUpdates()
        }
    }
}
