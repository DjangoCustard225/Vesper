import Foundation

/// Shares work only while it is running. Each caller owns an independent subscription.
public actor SharedRequestPool<Value: Sendable> {
    private struct Request {
        let id: UUID
        let task: Task<Void, Never>
        let demand: ArtworkDemand
        var waiters: [UUID: CheckedContinuation<Value, Error>]
    }
    private var requests: [String: Request] = [:]
    public init() {}
    func subscriberCount(for key: String) -> Int { requests[key]?.waiters.count ?? 0 }
    public func promote(_ key: String) { requests[key]?.demand.promote() }

    public func value(for key: String, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await value(for: key, priority: .visible) { _ in try await operation() }
    }
    public func value(for key: String, priority: ArtworkPriority,
                      onPromotion: @escaping @Sendable () async -> Void = {},
                      operation: @escaping @Sendable (ArtworkDemand) async throws -> Value) async throws -> Value {
        let subscriber = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                if var pending = requests[key] {
                    if priority == .visible && pending.demand.priority == .prefetch {
                        pending.demand.promote()
                        Task { await onPromotion() }
                    }
                    pending.waiters[subscriber] = continuation
                    requests[key] = pending
                } else {
                    let id = UUID()
                    let demand = ArtworkDemand(priority)
                    let task = Task {
                        let result: Result<Value, Error>
                        do { result = .success(try await operation(demand)) }
                        catch { result = .failure(error) }
                        self.complete(key, id: id, result: result)
                    }
                    requests[key] = Request(id: id, task: task, demand: demand, waiters: [subscriber: continuation])
                }
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { await self.cancel(key, subscriber: subscriber) }
        }
    }
    private func complete(_ key: String, id: UUID, result: Result<Value, Error>) {
        guard let request = requests[key], request.id == id else { return }
        requests[key] = nil
        for waiter in request.waiters.values { waiter.resume(with: result) }
    }
    private func cancel(_ key: String, subscriber: UUID) {
        guard var request = requests[key], let waiter = request.waiters.removeValue(forKey: subscriber) else { return }
        if request.waiters.isEmpty { requests[key] = nil; request.task.cancel() }
        else { requests[key] = request }
        waiter.resume(throwing: CancellationError())
    }
}
