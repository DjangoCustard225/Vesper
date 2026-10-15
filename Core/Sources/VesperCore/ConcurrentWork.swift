import Foundation

/// Schedules only a bounded number of children, preserving completion-time delivery.
public enum ConcurrentWork {
    public static func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], limit: Int = 4,
        isolation: isolated (any Actor)? = #isolation,
        operation: @escaping @Sendable (Input) async -> Output,
        onResult: (Int, Output) async -> Void
    ) async {
        await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            func enqueue() {
                let index = next, input = inputs[next]
                next += 1
                group.addTask { (index, await operation(input)) }
            }
            for _ in 0..<min(max(1, limit), inputs.count) where !Task.isCancelled { enqueue() }
            for await (index, output) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                await onResult(index, output)
                if next < inputs.count && !Task.isCancelled { enqueue() }
            }
        }
    }
}
