import Foundation
import Observation

public struct CombinedCatalogSource: Sendable {
    public let id: String
    public let title: String
    public let source: ContentSource

    public init(id: String, title: String, source: ContentSource) {
        self.id = id
        self.title = title
        self.source = source
    }
}

/// Settles each round in member order, then appends it without moving earlier rounds.
/// Cursors, exhaustion and failures belong to individual providers, not the merged list.
@MainActor @Observable
public final class CombinedCatalogController {
    public private(set) var items: [MediaItem] = []
    public private(set) var loading = false
    public private(set) var failures: [String: String] = [:]
    public private(set) var hasMore = false
    public private(set) var pageRevision = UUID()

    public var error: String? {
        let messages = sources.compactMap { member in
            failures[member.id].map { member.title + ": " + $0 }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private struct Contribution {
        let id: String
        let cursor: Int
        var page: ContentPage
    }

    private struct Job: Sendable {
        let member: CombinedCatalogSource
        let cursor: Int

        func fetch() async -> Result<ContentPage, Error> {
            do { return .success(try await member.source.fetch(cursor)) } catch { return .failure(error) }
        }
    }

    @ObservationIgnored private var sources: [CombinedCatalogSource] = []
    @ObservationIgnored private var cursors: [String: Int] = [:]
    @ObservationIgnored private var rounds: [[Contribution]] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var pendingUpdates: Set<String> = []

    public init() {}

    public func cancel() {
        generation = UUID()
        request?.cancel()
        request = nil
        pendingUpdates = []
        loading = false
    }

    public func load(_ sources: [CombinedCatalogSource]) async {
        cancel()
        var seen = Set<String>()
        self.sources = sources.filter { seen.insert($0.id).inserted }
        cursors = Dictionary(uniqueKeysWithValues: self.sources.map { ($0.id, $0.source.initialCursor) })
        rounds = []
        items = []
        failures = [:]
        hasMore = !cursors.isEmpty
        await loadMore()
    }

    public func loadMore() async { await fetchRound(retrying: false) }
    public func retry() async { await fetchRound(retrying: true) }

    private func fetchRound(retrying: Bool) async {
        guard !loading else { return }
        let jobs = sources.compactMap { member -> Job? in
            guard let cursor = cursors[member.id], (failures[member.id] != nil) == retrying else {
                return nil
            }
            return Job(member: member, cursor: cursor)
        }
        guard !jobs.isEmpty else { return }
        let current = generation
        loading = true
        let task = Task {
            var results: [Int: Result<ContentPage, Error>] = [:]
            await ConcurrentWork.run(jobs, operation: { await $0.fetch() }) { index, result in
                results[index] = result
            }
            guard self.generation == current, !Task.isCancelled else { return }
            var round: [Contribution] = []
            for (index, job) in jobs.enumerated() {
                guard let result = results[index] else { continue }
                let id = job.member.id
                switch result {
                case .success(let page):
                    self.failures[id] = nil
                    let previous = self.rounds.flatMap { $0 }.filter { $0.id == id }
                    let existing = MediaIdentity.unique(previous.flatMap { $0.page.items })
                    let grows = MediaIdentity.unique(existing + page.items).count > existing.count
                    let repeatedCursor =
                        page.nextCursor == job.cursor || previous.contains { $0.cursor == page.nextCursor }
                    self.cursors[id] = grows && !repeatedCursor ? page.nextCursor : nil
                    round.append(Contribution(id: id, cursor: job.cursor, page: page))
                case .failure(let error):
                    if !(error is CancellationError) { self.failures[id] = error.localizedDescription }
                }
            }
            if !round.isEmpty { self.rounds.append(round) }
            self.rebuild()
            self.finish(current)
        }
        request = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == current, loading {
            loading = false
            request = nil
            if !Task.isCancelled { drainUpdates() }
        }
    }

    public func refresh(cacheIDs: Set<String>) {
        pendingUpdates.formUnion(cacheIDs)
        drainUpdates()
    }

    private func rebuild() {
        items = MediaIdentity.unique(rounds.flatMap { CombinedCatalog.alternating($0.map { $0.page.items }) })
        hasMore = sources.contains { cursors[$0.id] != nil && failures[$0.id] == nil }
        pageRevision = UUID()
    }

    private func finish(_ current: UUID) {
        guard generation == current else { return }
        loading = false
        request = nil
        drainUpdates()
    }

    private func drainUpdates() {
        guard !loading, !pendingUpdates.isEmpty else { return }
        let changed = pendingUpdates
        pendingUpdates = []
        let locations = rounds.enumerated().flatMap { round, pages in
            pages.enumerated().compactMap { index, contribution -> (Int, Int, Job)? in
                guard let cacheID = contribution.page.cacheID, changed.contains(cacheID),
                    let member = sources.first(where: { $0.id == contribution.id })
                else { return nil }
                return (round, index, Job(member: member, cursor: contribution.cursor))
            }
        }
        guard !locations.isEmpty else { return }
        let current = generation
        loading = true
        request = Task {
            await ConcurrentWork.run(locations.map { $0.2 }, operation: { await $0.fetch() }) {
                index, result in
                guard self.generation == current, !Task.isCancelled else { return }
                if case .success(let page) = result {
                    let location = locations[index]
                    self.rounds[location.0][location.1].page = page
                }
            }
            guard self.generation == current, !Task.isCancelled else { return }
            self.rebuild()
            self.finish(current)
        }
    }
}
