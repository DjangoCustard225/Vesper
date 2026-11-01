import Foundation

/// Fallback connections are account capped and released before primary workers reconnect.
actor FallbackServer {
    private let config: ServerConfig
    private var active = 0
    private let rateLimiter: RateLimiter?
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []
    init(_ config: ServerConfig, rateLimiter: RateLimiter?) {
        self.config = config; self.rateLimiter = rateLimiter
    }

    func article(_ messageID: String) async throws -> [Data] {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < config.maxConnections {
                active += 1
            } else {
                try await withCheckedThrowingContinuation { waiters.append((id, $0)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        defer {
            if waiters.isEmpty { active -= 1 } else { waiters.removeFirst().1.resume() }
        }
        try Task.checkCancellation()
        let connection = NNTPConnection(config: config, rateLimiter: rateLimiter)
        do { try await connection.open() } catch { await connection.close(); throw error }

        do {
            let result = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: [Data].self) { group in
                    group.addTask { try await connection.fetchBody(messageID: messageID) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        await connection.close()
                        throw NNTPError.timeout
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? []
                }
            } onCancel: {
                Task { await connection.close() }
            }
            await connection.close()
            return result
        } catch { await connection.close(); throw error }
    }
    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }

}
