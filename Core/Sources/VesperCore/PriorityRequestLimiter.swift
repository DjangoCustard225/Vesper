import Foundation

public enum ArtworkPriority: Int, Sendable { case prefetch, visible }

public final class ArtworkDemand: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ArtworkPriority
    public init(_ priority: ArtworkPriority) { value = priority }
    public var priority: ArtworkPriority { lock.lock(); defer { lock.unlock() }; return value }
    public func promote() { lock.lock(); value = .visible; lock.unlock() }
}

/// Reserves capacity for visible work and promotes queued prefetches in place.
public actor PriorityRequestLimiter {
    private struct Waiter {
        let id: UUID
        let key: String
        var priority: ArtworkPriority
        let continuation: CheckedContinuation<UUID, Error>
    }
    private let limit: Int
    private let prefetchLimit: Int
    private var active: [UUID: (String, ArtworkPriority)] = [:]
    private var waiters: [Waiter] = []
    var queuedCount: Int { waiters.count }
    public init(limit: Int, prefetchLimit: Int) {
        self.limit = max(1, limit); self.prefetchLimit = max(0, min(prefetchLimit, limit))
    }
    public func promote(_ key: String) {
        for index in waiters.indices where waiters[index].key == key { waiters[index].priority = .visible }
        for (id, entry) in active where entry.0 == key { active[id] = (key, .visible) }
        drain()
    }
    private func acquire(_ key: String, priority: ArtworkPriority, demand: ArtworkDemand?) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, key: key, priority: demand?.priority ?? priority, continuation: continuation))
                drain()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func drain() {
        while active.count < limit {
            let speculative = active.values.filter { $0.1 == .prefetch }.count
            guard let index = waiters.firstIndex(where: { $0.priority == .visible })
                    ?? (speculative < prefetchLimit ? waiters.indices.first : nil) else { return }
            let waiter = waiters.remove(at: index)
            active[waiter.id] = (waiter.key, waiter.priority)
            waiter.continuation.resume(returning: waiter.id)
        }
    }
    private func release(_ id: UUID) { active[id] = nil; drain() }
    public func run<Value: Sendable>(key: String, priority: ArtworkPriority = .visible, demand: ArtworkDemand? = nil,
                                    operation: @Sendable () async throws -> Value) async throws -> Value {
        let id = try await acquire(key, priority: priority, demand: demand)
        defer { release(id) }
        try Task.checkCancellation()
        return try await operation()
    }
}
