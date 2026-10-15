import Foundation
import Observation

public struct CatalogFeed: Identifiable, Sendable {
    public let addon: InstalledAddon
    public let catalog: AddonCatalog
    public fileprivate(set) var items: [MediaItem] = []
    public fileprivate(set) var error: String?

    public var id: String { addon.id + ":" + catalog.type + ":" + catalog.id }

    public var subtitle: String {
        addon.manifest.name + " · " + (catalog.type == "series" ? "Series" : catalog.type.capitalized)
    }

    public init(addon: InstalledAddon, catalog: AddonCatalog) {
        self.addon = addon
        self.catalog = catalog
    }
}

public struct TMDBFeed: Identifiable, Sendable {
    public let catalog: TMDBCatalog
    public fileprivate(set) var items: [MediaItem] = []
    public fileprivate(set) var error: String?

    public var id: String { catalog.id }

    public init(catalog: TMDBCatalog) { self.catalog = catalog }
}

/// Describes a home shelf independently of its position in the two feed collections.
public enum HomeCatalog: Sendable {
    case addon(CatalogFeed)
    case tmdb(TMDBCatalog)
}

/// Owns home-feed requests, incremental delivery, and cache revalidation.
/// Failed refreshes retain previously loaded artwork; superseded requests cannot mutate new feeds.
@MainActor @Observable
public final class HomeFeedController {
    public private(set) var feeds: [CatalogFeed] = []
    public private(set) var tmdbFeeds: [TMDBFeed] = []
    public private(set) var isLoading = false

    private enum Target: Hashable, Sendable {
        case addon(String)
        case tmdb(TMDBCatalog)
    }

    private struct Job: Sendable {
        let target: Target
        let source: ContentSource

        func fetch() async -> Result<ContentPage, Error> {
            do { return .success(try await source.fetch(source.initialCursor)) } catch {
                return .failure(error)
            }
        }
    }

    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var revalidation: Task<Void, Never>?
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var cacheIDs: [Target: String] = [:]
    @ObservationIgnored private var pendingUpdates: Set<String> = []

    public init() {}

    public func cancel() {
        generation = UUID()
        request?.cancel()
        request = nil
        revalidation?.cancel()
        revalidation = nil
        pendingUpdates = []
        jobs = []
        cacheIDs = [:]
        isLoading = false
    }

    public func load(
        addons: [InstalledAddon], includeTMDB: Bool,
        source: (HomeCatalog) -> ContentSource
    ) async {
        cancel()
        let current = generation
        let previousFeeds = feeds
        let previousTMDB = tmdbFeeds
        feeds = addons.filter(\.isEnabled).flatMap { addon in
            addon.manifest.catalogs.filter { $0.canRequest(with: $0.defaultExtras) }.map { catalog in
                var feed = CatalogFeed(addon: addon, catalog: catalog)
                feed.items = previousFeeds.first { $0.id == feed.id }?.items ?? []
                return feed
            }
        }
        tmdbFeeds =
            includeTMDB
            ? TMDBCatalog.allCases.map { catalog in
                var feed = TMDBFeed(catalog: catalog)
                feed.items = previousTMDB.first { $0.catalog == catalog }?.items ?? []
                return feed
            } : []
        jobs =
            tmdbFeeds.map { Job(target: .tmdb($0.catalog), source: source(.tmdb($0.catalog))) }
            + feeds.map { Job(target: .addon($0.id), source: source(.addon($0))) }
        for job in jobs { cacheIDs[job.target] = job.source.initialCacheID }
        let jobs = jobs
        isLoading = true
        let task = Task {
            await ConcurrentWork.run(jobs, operation: { await $0.fetch() }) { index, result in
                guard self.generation == current, !Task.isCancelled else { return }
                self.apply(result, to: jobs[index].target, reportsFailure: true)
            }
        }
        request = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == current else { return }
        request = nil
        isLoading = false
        if !Task.isCancelled { drainUpdates() }
    }

    /// Coalesces updates arriving during initial loading or an existing revalidation.
    public func refresh(cacheIDs: Set<String>) {
        pendingUpdates.formUnion(cacheIDs)
        drainUpdates()
    }

    func flushUpdates() async {
        while let revalidation { await revalidation.value }
    }

    private func drainUpdates() {
        guard !isLoading, revalidation == nil, !pendingUpdates.isEmpty else { return }
        let changed = pendingUpdates
        pendingUpdates = []
        let affected = jobs.filter { job in
            cacheIDs[job.target].map { changed.contains($0) } ?? false
        }
        guard !affected.isEmpty else { return }
        let current = generation
        revalidation = Task {
            await ConcurrentWork.run(affected, operation: { await $0.fetch() }) { index, result in
                guard self.generation == current, !Task.isCancelled else { return }
                self.apply(result, to: affected[index].target, reportsFailure: false)
            }
            guard self.generation == current else { return }
            self.revalidation = nil
            self.drainUpdates()
        }
    }

    private func apply(_ result: Result<ContentPage, Error>, to target: Target, reportsFailure: Bool) {
        let items: [MediaItem]?
        let failure: String?
        switch result {
        case .success(let page):
            if let cacheID = page.cacheID { cacheIDs[target] = cacheID }
            items = page.items
            failure = nil
        case .failure(let error):
            guard reportsFailure, !(error is CancellationError) else { return }
            items = nil
            failure = error.localizedDescription
        }
        switch target {
        case .tmdb(let catalog):
            guard let index = tmdbFeeds.firstIndex(where: { $0.catalog == catalog }) else { return }
            if let items { tmdbFeeds[index].items = items }
            tmdbFeeds[index].error = failure
        case .addon(let id):
            guard let index = feeds.firstIndex(where: { $0.id == id }) else { return }
            if let items { feeds[index].items = items }
            feeds[index].error = failure
        }
    }
}
