import Foundation

public struct RetryPolicy: Sendable {
    public let attempts: Int
    public let baseDelay: TimeInterval
    public let budget: TimeInterval

    public init(attempts: Int = 3, baseDelay: TimeInterval = 0.3, budget: TimeInterval = 40) {
        self.attempts = max(1, attempts)
        self.baseDelay = max(0, baseDelay)
        self.budget = max(0, budget)
    }

    public func delay(
        status: Int?, error: URLError.Code?, retryAfter: String?, attempt: Int, elapsed: TimeInterval,
        now: Date = Date()
    ) -> TimeInterval? {
        guard attempt < attempts else { return nil }
        let retryable =
            status.map { [408, 429, 500, 502, 503, 504].contains($0) }
            ?? error.map { [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains($0) } ?? false
        guard retryable else { return nil }
        var delay = baseDelay * pow(2, Double(attempt - 1))
        if let retryAfter {
            if let seconds = Double(retryAfter), seconds.isFinite {
                delay = max(delay, seconds)
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)

                formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
                if let date = formatter.date(from: retryAfter) {
                    delay = max(delay, date.timeIntervalSince(now))
                }
            }
        }
        // Never shorten a provider's Retry-After to squeeze in another request.
        guard delay.isFinite, delay >= 0, elapsed + delay < budget else { return nil }
        return delay
    }
}
