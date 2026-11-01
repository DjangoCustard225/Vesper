import Foundation
import Observation

@MainActor @Observable public final class NZBFinderSearchController {
    public private(set) var releases: [NZBRelease] = []
    public private(set) var loading = false
    public private(set) var hasSearched = false
    public private(set) var error: String?
    public private(set) var next: NZBSearchCursor?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var fetch: (@MainActor (NZBSearchCursor?) async throws -> NZBSearchPage)?
    public init() {}
    public func cancel() {
        generation = UUID(); request?.cancel(); request = nil; loading = false; fetch = nil
    }
    public func clear(error: String? = nil) {
        cancel(); releases = []; next = nil; fetch = nil; hasSearched = false; self.error = error
    }
    public func load(fetch: @escaping @MainActor (NZBSearchCursor?) async throws -> NZBSearchPage) async {
        clear(); self.fetch = fetch; await page(nil)
    }
    public func loadNext() async { if let next { await page(next) } }
    private func page(_ cursor: NZBSearchCursor?) async {
        guard !loading, let fetch else { return }
        let current = generation; loading = true; error = nil
        var skippedPage = false
        let task = Task {
            do {
                let page = try await fetch(cursor)
                guard !Task.isCancelled, generation == current else { return }
                hasSearched = true
                skippedPage = page.releases.isEmpty
                var seen = Set(releases.map(\.id))
                let fresh = page.releases.filter { seen.insert($0.id).inserted }
                releases += fresh
                next = (!fresh.isEmpty || page.releases.isEmpty) && page.next != cursor ? page.next : nil
            } catch is CancellationError {} catch {
                if generation == current { self.error = error.localizedDescription }
            }
            if generation == current { loading = false; request = nil }
        }
        request = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == current {
            loading = false
            if error == nil, skippedPage, next != nil { await loadNext() }
        }
    }
}
