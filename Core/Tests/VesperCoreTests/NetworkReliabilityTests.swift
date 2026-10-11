import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ReliabilityURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class NetworkReliabilityTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReliabilityURLProtocol.self]
        return URLSession(configuration: configuration)
    }
    override func tearDown() { ReliabilityURLProtocol.handler = nil; super.tearDown() }
    func testTransientFailureRetriesAndDiagnosticsNeverContainRequestSecrets() async throws {
        let calls = LockedRequestCounter(), recorder = DiagnosticRecorder()
        ReliabilityURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer header-secret")
            return (calls.increment() == 1 ? 503 : 200, [:], Data("body-secret".utf8))
        }
        var request = URLRequest(url: URL(string: "https://provider.example/private-path-secret?api_key=query-secret")!)
        request.setValue("Bearer header-secret", forHTTPHeaderField: "Authorization")
        let transport = HTTPTransport(session: session(), policy: RetryPolicy(baseDelay: 0), diagnostics: recorder)
        let (data, response) = try await transport.data(for: request, operation: .streams)
        XCTAssertEqual(response.statusCode, 200); XCTAssertEqual(data, Data("body-secret".utf8)); XCTAssertEqual(calls.value, 2)
        let diagnostics = try await recorder.export()
        let events = try JSONDecoder().decode([DiagnosticEvent].self, from: diagnostics)
        XCTAssertEqual(events.map(\.attempt), [1, 2]); XCTAssertEqual(events.map(\.status), [503, 200])
        let text = String(decoding: diagnostics, as: UTF8.self)
        for secret in ["header-secret", "query-secret", "body-secret", "private-path-secret", "provider.example"] { XCTAssertFalse(text.contains(secret)) }
    }
    func testPermanentAuthenticationFailureIsNotRetried() async throws {
        let calls = LockedRequestCounter()
        ReliabilityURLProtocol.handler = { _ in calls.increment(); return (401, [:], Data()) }
        let result = try await HTTPTransport(session: session(), policy: RetryPolicy(baseDelay: 0), diagnostics: DiagnosticRecorder())
            .data(for: URLRequest(url: URL(string: "https://example.com")!), operation: .tmdb)
        XCTAssertEqual(result.1.statusCode, 401); XCTAssertEqual(calls.value, 1)
    }
    func testTimeoutRetriesAreBoundedAndCancellationIsPreserved() async throws {
        let calls = LockedRequestCounter()
        ReliabilityURLProtocol.handler = { _ in calls.increment(); throw URLError(.timedOut) }
        let transport = HTTPTransport(session: session(), policy: RetryPolicy(baseDelay: 0), diagnostics: DiagnosticRecorder())
        do { _ = try await transport.data(for: URLRequest(url: URL(string: "https://example.com")!), operation: .catalog); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(calls.value, 3)
        ReliabilityURLProtocol.handler = { _ in throw URLError(.cancelled) }
        do { _ = try await transport.data(for: URLRequest(url: URL(string: "https://example.com")!), operation: .catalog); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCancellationDuringBackoffDoesNotIssueAnotherRequest() async throws {
        let started = expectation(description: "First attempt")
        let calls = LockedRequestCounter()
        ReliabilityURLProtocol.handler = { _ in calls.increment(); started.fulfill(); return (429, ["Retry-After": "2"], Data()) }
        let transport = HTTPTransport(session: session(), diagnostics: DiagnosticRecorder())
        let task = Task { try await transport.data(for: URLRequest(url: URL(string: "https://example.com")!), operation: .tmdb) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.value, 1)
    }
    func testRetryAfterDateAndBudgetAreRespected() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let policy = RetryPolicy(baseDelay: 0.25, budget: 20)
        XCTAssertEqual(policy.delay(status: 429, error: nil, retryAfter: "5", attempt: 1, elapsed: 0), 5)
        XCTAssertEqual(policy.delay(status: 503, error: nil, retryAfter: formatter.string(from: now.addingTimeInterval(10)), attempt: 1, elapsed: 0, now: now), 10)
        XCTAssertNil(policy.delay(status: 429, error: nil, retryAfter: "30", attempt: 1, elapsed: 0))
        XCTAssertNil(policy.delay(status: 503, error: nil, retryAfter: nil, attempt: 3, elapsed: 0))
        XCTAssertNil(policy.delay(status: 404, error: nil, retryAfter: nil, attempt: 1, elapsed: 0))
    }
    func testDiagnosticsSurviveRestartAndStayBounded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(directory: directory)
        for attempt in 0..<205 {
            await recorder.record(DiagnosticEvent(date: Date(), operation: .catalog, attempt: attempt, milliseconds: 5, status: 200, outcome: .success))
        }
        await recorder.flush()
        let restarted = DiagnosticRecorder(directory: directory)
        let data = try await restarted.export()
        let events = try JSONDecoder().decode([DiagnosticEvent].self, from: data)
        XCTAssertEqual(events.count, 200); XCTAssertEqual(events.first?.attempt, 5)
    }
}
