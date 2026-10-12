import Foundation

/// Owns a scrolling window's subscriptions, retaining work shared by successive windows.
@MainActor public final class ArtworkPrefetchController {
    private struct Work: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    private let limit: Int
    private let load: @Sendable (URL) async -> Void
    private var urls: [URL] = []
    private var running: [URL: Work] = [:]
    private var completed: Set<URL> = []

    public init(limit: Int = 2, load: @escaping @Sendable (URL) async -> Void) {
        self.limit = max(1, limit)
        self.load = load
    }
    deinit { for work in running.values { work.task.cancel() } }

    public func update(_ urls: [URL]) {
        var wanted = Set<URL>()
        self.urls = urls.filter { wanted.insert($0).inserted }
        completed.formIntersection(wanted)
        for (url, work) in running where !wanted.contains(url) {
            running[url] = nil
            work.task.cancel()
        }
        schedule()
    }
    public func cancel() {
        urls = []; completed = []
        let previous = running
        running = [:]
        for work in previous.values { work.task.cancel() }
    }
    private func schedule() {
        let load = load
        for url in urls where running[url] == nil && !completed.contains(url) {
            guard running.count < limit else { break }
            let id = UUID()
            let task = Task { [weak self] in
                await load(url)
                guard !Task.isCancelled else { return }
                self?.finish(url, id: id)
            }
            running[url] = Work(id: id, task: task)
        }
    }
    private func finish(_ url: URL, id: UUID) {
        guard running[url]?.id == id else { return }
        running[url] = nil
        completed.insert(url)
        schedule()
    }
}
