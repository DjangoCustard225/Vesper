import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum NetworkOperation: String, Codable, Sendable {
    case tmdb, manifest, catalog, metadata, streams, artwork
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .metadata
    }
}
public enum DiagnosticOutcome: String, Codable, Sendable { case success, http, timeout, offline, network }

public struct DiagnosticEvent: Codable, Sendable {
    public let date: Date
    public let operation: NetworkOperation
    public let attempt: Int
    public let milliseconds: Int
    public let status: Int?
    public let outcome: DiagnosticOutcome
}

/// Deliberately accepts no URLs, headers, response bodies, or arbitrary error text.
public actor DiagnosticRecorder {
    public static let shared = DiagnosticRecorder(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("VesperDiagnostics"))
    private let directory: URL?
    private var events: [DiagnosticEvent] = []
    private let flushInterval: Duration
    private let batchSize: Int
    private var unsaved = 0
    private var flushTask: Task<Void, Never>?
    public init(directory: URL? = nil, flushInterval: Duration = .seconds(1), batchSize: Int = 20) {
        self.directory = directory
        self.flushInterval = flushInterval; self.batchSize = max(1, batchSize)
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("requests.json")), data.count <= 128 * 1024,
           let saved = try? JSONDecoder().decode([DiagnosticEvent].self, from: data) { events = Array(saved.suffix(200)) }
    }
    public func record(_ event: DiagnosticEvent) {
        events.append(event)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        guard directory != nil else { return }
        unsaved += 1
        if unsaved >= batchSize { flush() }
        else if flushTask == nil {
            let interval = flushInterval
            flushTask = Task { [weak self] in
                do { try await Task.sleep(for: interval); try Task.checkCancellation() }
                catch { return }
                await self?.flush()
            }
        }
    }
    public func flush() {
        flushTask?.cancel(); flushTask = nil
        guard unsaved > 0 else { return }
        guard let directory, let data = try? JSONEncoder().encode(events) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("requests.json"), options: .atomic)
            unsaved = 0
        } catch { /* Diagnostics must not interrupt browsing; retry on the next batch or flush. */ }
    }
    public func export() throws -> Data {
        flush()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(events)
    }
}

public struct RetryPolicy: Sendable {
    public var attempts: Int
    public var baseDelay: TimeInterval
    public var budget: TimeInterval
    public init(attempts: Int = 3, baseDelay: TimeInterval = 0.3, budget: TimeInterval = 40) {
        self.attempts = max(1, attempts); self.baseDelay = max(0, baseDelay); self.budget = max(0, budget)
    }
    public func delay(status: Int?, error: URLError.Code?, retryAfter: String?, attempt: Int, elapsed: TimeInterval, now: Date = Date()) -> TimeInterval? {
        guard attempt < attempts else { return nil }
        let retryable = status.map { [408, 429, 500, 502, 503, 504].contains($0) }
            ?? error.map { [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains($0) } ?? false
        guard retryable else { return nil }
        var delay = baseDelay * pow(2, Double(attempt - 1))
        if let retryAfter {
            if let seconds = Double(retryAfter), seconds.isFinite { delay = max(delay, seconds) }
            else {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
                if let date = formatter.date(from: retryAfter) { delay = max(delay, date.timeIntervalSince(now)) }
            }
        }
        // Never shorten a provider's Retry-After to squeeze in another request.
        guard delay.isFinite, delay >= 0, elapsed + delay < budget else { return nil }
        return delay
    }
}

public struct HTTPTransport: Sendable {
    private let session: URLSession
    private let policy: RetryPolicy
    private let diagnostics: DiagnosticRecorder
    private let requestTimeout: TimeInterval
    public init(session: URLSession, policy: RetryPolicy = RetryPolicy(), diagnostics: DiagnosticRecorder = .shared, requestTimeout: TimeInterval = 15) {
        self.session = session; self.policy = policy; self.diagnostics = diagnostics; self.requestTimeout = requestTimeout
    }
    public func data(for request: URLRequest, operation: NetworkOperation) async throws -> (Data, HTTPURLResponse) {
        let start = Date()
        for attempt in 1...policy.attempts {
            try Task.checkCancellation()
            let began = Date()
            var status: Int?
            do {
                var bounded = request
                bounded.timeoutInterval = min(requestTimeout, request.timeoutInterval, max(0.1, policy.budget - Date().timeIntervalSince(start)))
                let (data, response) = try await session.data(for: bounded)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                status = http.statusCode
                await diagnostics.record(DiagnosticEvent(date: began, operation: operation, attempt: attempt,
                    milliseconds: max(0, Int(Date().timeIntervalSince(began) * 1000)), status: status, outcome: (200..<300).contains(http.statusCode) ? .success : .http))
                if request.httpMethod == nil || request.httpMethod == "GET",
                   let delay = policy.delay(status: status, error: nil, retryAfter: http.value(forHTTPHeaderField: "Retry-After"), attempt: attempt, elapsed: Date().timeIntervalSince(start)) {
                    try await Task.sleep(for: .seconds(delay)); continue
                }
                return (data, http)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                // A sleep failure after a recorded HTTP response must not issue a second retry.
                guard status == nil else { throw error }
                let code = (error as? URLError)?.code
                await diagnostics.record(DiagnosticEvent(date: began, operation: operation, attempt: attempt,
                    milliseconds: max(0, Int(Date().timeIntervalSince(began) * 1000)), status: nil,
                    outcome: code == .timedOut ? .timeout : code == .notConnectedToInternet ? .offline : .network))
                if request.httpMethod == nil || request.httpMethod == "GET",
                   let delay = policy.delay(status: nil, error: code, retryAfter: nil, attempt: attempt, elapsed: Date().timeIntervalSince(start)) {
                    try await Task.sleep(for: .seconds(delay)); continue
                }
                throw error
            }
        }
        throw URLError(.timedOut)
    }
}
