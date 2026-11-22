import Foundation

public struct RetryPolicy: Sendable {
    /// Space TMDB retries over several seconds so short gateway outages have time to recover.
    /// Connection failures (offline, host unreachable) give up sooner so screens fail fast.
    public static let tmdb = RetryPolicy(attempts: 4, baseDelay: 1, connectionAttempts: 2)
    public let attempts: Int
    /// Attempt limit for transport errors with no HTTP status; defaults to `attempts`.
    public let connectionAttempts: Int
    public let baseDelay: TimeInterval
    public let budget: TimeInterval

    public init(
        attempts: Int = 3, baseDelay: TimeInterval = 0.3, budget: TimeInterval = 40,
        connectionAttempts: Int? = nil
    ) {
        self.attempts = max(1, attempts)
        self.connectionAttempts = max(1, min(self.attempts, connectionAttempts ?? attempts))
        self.baseDelay = max(0, baseDelay)
        self.budget = max(0, budget)
    }

    public func delay(
        status: Int?, error: URLError.Code?, retryAfter: String?, attempt: Int, elapsed: TimeInterval,
        now: Date = Date()
    ) -> TimeInterval? {
        guard attempt < (status == nil && error != nil ? connectionAttempts : attempts) else { return nil }
        let retryable =
            status.map { [408, 429, 500, 502, 503, 504].contains($0) }
            ?? error.map { [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains($0) } ?? false
        guard retryable else { return nil }
        var delay = baseDelay * pow(2, Double(attempt - 1))
        if let retryAfter {
            if let seconds = Double(retryAfter), seconds.isFinite {
                delay = max(delay, seconds)
            } else {
                if let date = FixedDateParser.http.date(from: retryAfter) {
                    delay = max(delay, date.timeIntervalSince(now))
                }
            }
        }
        // Never shorten a provider's Retry-After to squeeze in another request.
        guard delay.isFinite, delay >= 0, elapsed + delay < budget else { return nil }
        return delay
    }
}
