import Foundation
import Observation

public struct CatalogFeed: Identifiable, Sendable {
    public let addon: InstalledAddon
    public let catalog: AddonCatalog
    public fileprivate(set) var items: [MediaItem] = []
    public fileprivate(set) var error: String?

    public var id: String { addon.id + ":" + catalog.type + ":" + catalog.id }

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
    case combined(CombinedCatalog)
}

/// Owns home-feed requests, incremental delivery, and cache revalidation.
/// Failed refreshes retain previously loaded artwork; superseded requests cannot mutate new feeds.
@MainActor @Observable
public final class HomeFeedController {
    public private(set) var feeds: [CatalogFeed] = []
    public private(set) var tmdbFeeds: [TMDBFeed] = []
    public private(set) var isLoading = false
    public private(set) var settledCatalogIDs: Set<String> = []
    public private(set) var presentationRevision = UUID()

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
    @ObservationIgnored private var completed: Set<Target> = []
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
        completed = []
        settledCatalogIDs = []
        isLoading = false
        presentationRevision = UUID()
    }

    public func load(
        catalogs: [HomeCatalog], preservingUnchanged: Bool = false, source: (HomeCatalog) -> ContentSource?
    ) async {
        let previousFeeds = feeds, previousTMDB = tmdbFeeds, previousCacheIDs = cacheIDs
        let previousCompleted = completed
        cancel()
        let current = generation
        var seen = Set<String>()
        let catalogs = catalogs.filter { catalog in
            guard seen.insert(catalog.id).inserted else { return false }
            if case .combined = catalog { return false }
            if case .addon(let feed) = catalog { return feed.addon.isEnabled }
            return true
        }
        let entries = catalogs.compactMap { catalog -> (HomeCatalog, Job)? in
            guard let source = source(catalog) else { return nil }
            switch catalog {
            case .addon(let feed): return (catalog, Job(target: .addon(feed.id), source: source))
            case .tmdb(let value): return (catalog, Job(target: .tmdb(value), source: source))
            case .combined: return nil
            }
        }
        jobs = entries.map { $0.1 }
        feeds = []
        tmdbFeeds = []
        for (catalog, job) in entries {
            let sameRequest = previousCacheIDs[job.target] == job.source.initialCacheID
            if sameRequest, previousCompleted.contains(job.target) {
                completed.insert(job.target)
                settledCatalogIDs.insert(catalog.id)
            }
            switch catalog {
            case .addon(var feed):
                let previous = sameRequest ? previousFeeds.first { $0.id == feed.id } : nil
                feed.items = previous?.items ?? []
                feed.error = previous?.error
                feeds.append(feed)
            case .tmdb(let value):
                var feed = TMDBFeed(catalog: value)
                let previous = sameRequest ? previousTMDB.first { $0.catalog == value } : nil
                feed.items = previous?.items ?? []
                feed.error = previous?.error
                tmdbFeeds.append(feed)
            case .combined: break
            }
            cacheIDs[job.target] = job.source.initialCacheID
        }
        let jobs = jobs.filter { !preservingUnchanged || !completed.contains($0.target) }
        isLoading = !jobs.isEmpty
        presentationRevision = UUID()
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
        presentationRevision = UUID()
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
            completed.insert(target)
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
            settledCatalogIDs.insert("tmdb:" + catalog.id)
            guard let index = tmdbFeeds.firstIndex(where: { $0.catalog == catalog }) else { return }
            if let items { tmdbFeeds[index].items = items }
            tmdbFeeds[index].error = failure
        case .addon(let id):
            settledCatalogIDs.insert("addon:" + id)
            guard let index = feeds.firstIndex(where: { $0.id == id }) else { return }
            if let items { feeds[index].items = items }
            feeds[index].error = failure
        }
        presentationRevision = UUID()
    }
}
