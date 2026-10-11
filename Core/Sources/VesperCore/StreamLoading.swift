import Foundation
import Observation

public struct StreamOption: Identifiable, Sendable {
    public var id: String { StreamPolicy.identity(source) }
    public let addonName: String
    public let source: StreamSource
    public var provider: InstalledAddon?
    public var fetchedAt: Date
    public init(addonName: String, source: StreamSource, provider: InstalledAddon? = nil, fetchedAt: Date = Date()) {
        self.addonName = addonName; self.source = source; self.provider = provider; self.fetchedAt = fetchedAt
    }
}

public struct StreamResults: Sendable {
    public var options: [StreamOption]
    public var failures: [String]
    public init(options: [StreamOption] = [], failures: [String] = []) { self.options = options; self.failures = failures }
    public func playable() -> StreamResults {
        var seen = Set<String>(), skipped = 0
        let supported = options.filter {
            guard StreamPolicy.isPlayable($0.source) else { skipped += 1; return false }
            return seen.insert($0.id).inserted
        }
        var failures = failures
        if skipped > 0 { failures.append("\(skipped) source\(skipped == 1 ? "" : "s") can’t be opened directly in an external player. Use providers with HTTP video sources.") }
        return StreamResults(options: supported, failures: failures)
    }
}

@MainActor @Observable
public final class StreamLoadingController {
    public private(set) var result = StreamResults()
    public private(set) var loading = true
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var key: String?
    public init() {}
    public func cancel() { generation = UUID(); request?.cancel(); request = nil; loading = false }
    public func load(key: String, fetch: @escaping @MainActor (@escaping @MainActor (StreamResults) -> Void) async -> StreamResults) async {
        cancel()
        if self.key != key { result = StreamResults(); self.key = key }
        let current = generation
        loading = true
        let task = Task {
            let next = await fetch { partial in
                guard self.generation == current, !Task.isCancelled, !partial.options.isEmpty else { return }
                self.result = partial; self.loading = false
            }
            guard self.generation == current, !Task.isCancelled else { return }
            self.result = next; self.loading = false; self.request = nil
        }
        request = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if generation == current { loading = false }
    }
}
