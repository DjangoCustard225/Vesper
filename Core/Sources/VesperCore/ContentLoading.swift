import Foundation
import Observation

public struct ContentPage: Sendable {
    public var items: [MediaItem]
    public let nextCursor: Int?
    public let cacheID: String?

    public init(items: [MediaItem], nextCursor: Int? = nil, cacheID: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.cacheID = cacheID
    }
}

public struct ContentSource: Sendable {
    public let initialCursor: Int
    /// Identifies the initial page even if its first request fails before returning a page.
    public let initialCacheID: String?
    public let fetch: @MainActor @Sendable (Int) async throws -> ContentPage

    public init(
        initialCursor: Int = 1, initialCacheID: String? = nil,
        fetch: @escaping @MainActor @Sendable (Int) async throws -> ContentPage
    ) {
        self.initialCursor = initialCursor
        self.initialCacheID = initialCacheID
        self.fetch = fetch
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
        generation = UUID()
        request?.cancel()
        refreshing?.cancel()
        refreshing = nil
        pendingUpdates = []
        loading = false
    }

    public func load(_ source: ContentSource) async {
        cancel()
        self.source = source
        pages = [:]
        items = []
        error = nil
        nextCursor = source.initialCursor
        hasMore = true
        await loadMore()
    }

    public func loadMore() async {
        guard !loading, let source, let cursor = nextCursor else { return }
        let current = generation
        loading = true
        error = nil
        let task = Task {
            do {
                let page = try await source.fetch(cursor)
                guard !Task.isCancelled, self.generation == current else { return }
                let merged = CatalogPagination(
                    existing: self.items, incoming: page.items,
                    providerHasMore: page.nextCursor != nil)
                self.pages[cursor] = page
                self.rebuild()
                self.hasMore = merged.hasMore
                self.nextCursor = merged.hasMore ? page.nextCursor : nil
                self.pageRevision = UUID()
            } catch is CancellationError {} catch {
                if self.generation == current { self.error = error.localizedDescription }
            }
            if self.generation == current {
                self.loading = false
                self.drainUpdates()
            }
        }
        request = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == current { loading = false }
    }

    public func refresh(cacheIDs: Set<String>) {
        pendingUpdates.formUnion(
            loading ? cacheIDs : cacheIDs.intersection(Set(pages.values.compactMap(\.cacheID))))

        drainUpdates()
    }

    private func rebuild() {
        items = MediaIdentity.unique(pages.sorted { $0.key < $1.key }.flatMap { $0.value.items })
    }

    private func drainUpdates() {
        guard !loading, refreshing == nil, let source, !pendingUpdates.isEmpty else { return }
        let changed = pendingUpdates
        pendingUpdates = []
        let current = generation
        let cursors = pages.filter { $0.value.cacheID.map { changed.contains($0) } == true }.keys.sorted()
        refreshing = Task {
            for cursor in cursors {
                guard !Task.isCancelled, self.generation == current else { return }
                do {
                    let page = try await source.fetch(cursor)
                    guard !Task.isCancelled, self.generation == current else { return }
                    self.pages[cursor] = page
                    self.rebuild()
                } catch { /* A failed revalidation must not hide loaded pages. */  }
            }
            guard self.generation == current else { return }
            self.refreshing = nil
            self.drainUpdates()
        }
    }
}
