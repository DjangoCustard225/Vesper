import Foundation

/// Schedules only a bounded number of children, preserving completion-time delivery.
public enum ConcurrentWork {
    public static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], limit: Int = 4,
        operation: @escaping @Sendable (Input) async -> Output,
        onResult: (Int, Output) async -> Void
    ) async {
        await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            func enqueue() {
                let index = next, input = inputs[next]; next += 1
                group.addTask { (index, await operation(input)) }
            }
            for _ in 0..<min(max(1, limit), inputs.count) where !Task.isCancelled { enqueue() }
            for await (index, output) in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                await onResult(index, output)
                if next < inputs.count && !Task.isCancelled { enqueue() }
            }
        }
    }
}

/// Shared by an add-on client so overlapping screens also respect its request limit.
public actor RequestLimiter {
    private let limit: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    public init(limit: Int = 4) { self.limit = max(1, limit) }
    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < limit { active += 1; return }
            try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume() }
    }
    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
}
