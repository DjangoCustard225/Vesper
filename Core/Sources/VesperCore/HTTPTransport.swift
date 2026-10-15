import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPTransport: Sendable {
    private let session: URLSession
    private let policy: RetryPolicy
    private let diagnostics: DiagnosticRecorder
    private let requestTimeout: TimeInterval

    public init(
        session: URLSession, policy: RetryPolicy = RetryPolicy(), diagnostics: DiagnosticRecorder = .shared,
        requestTimeout: TimeInterval = 15
    ) {
        self.session = session
        self.policy = policy
        self.diagnostics = diagnostics

        self.requestTimeout = requestTimeout
    }

    public func data(for request: URLRequest, operation: NetworkOperation, byteLimit: Int? = nil) async throws
        -> (Data, HTTPURLResponse)
    {
        let start = Date()
        for attempt in 1...policy.attempts {
            try Task.checkCancellation()
            let began = Date()
            var status: Int?
            do {
                var bounded = request
                bounded.timeoutInterval = min(
                    requestTimeout, request.timeoutInterval,
                    max(0.1, policy.budget - Date().timeIntervalSince(start)))
                let (data, http) = try await BoundedResponse.data(
                    for: bounded, session: session,
                    limit: byteLimit ?? operation.responseByteLimit)
                try Task.checkCancellation()
                status = http.statusCode
                await diagnostics.record(
                    DiagnosticEvent(
                        date: began, operation: operation, attempt: attempt,
                        milliseconds: max(0, Int(Date().timeIntervalSince(began) * 1000)), status: status,
                        outcome: (200..<300).contains(http.statusCode) ? .success : .http))
                if request.httpMethod == nil || request.httpMethod == "GET",
                    let delay = policy.delay(
                        status: status, error: nil, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                        attempt: attempt, elapsed: Date().timeIntervalSince(start))
                {
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                return (data, http)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                // A sleep failure after a recorded HTTP response must not issue a second retry.
                guard status == nil else { throw error }
                let code = (error as? URLError)?.code
                await diagnostics.record(
                    DiagnosticEvent(
                        date: began, operation: operation, attempt: attempt,
                        milliseconds: max(0, Int(Date().timeIntervalSince(began) * 1000)), status: nil,
                        outcome: code == .timedOut
                            ? .timeout : code == .notConnectedToInternet ? .offline : .network))
                if request.httpMethod == nil || request.httpMethod == "GET",
                    let delay = policy.delay(
                        status: nil, error: code, retryAfter: nil, attempt: attempt,
                        elapsed: Date().timeIntervalSince(start))
                {
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                throw error
            }
        }
        throw URLError(.timedOut)
    }
}
