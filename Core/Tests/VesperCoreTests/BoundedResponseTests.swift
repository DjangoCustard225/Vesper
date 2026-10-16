import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class BoundedResponseTests: XCTestCase {
    private let fixture = HTTPFixture()
    private let url = URL(string: "https://provider.example/response")!

    private func transport() -> HTTPTransport {
        HTTPTransport(
            session: fixture.session(), policy: RetryPolicy(baseDelay: 0), diagnostics: DiagnosticRecorder())
    }

    func testChunkedResponseAtLimitKeepsEveryByte() async throws {
        fixture.respond = { _ in
            var response = FixtureResponse()
            response.chunks = [Data([1, 2]), Data([3, 4])]
            return response
        }
        let (body, response) = try await transport().data(
            for: URLRequest(url: url), operation: .catalog, byteLimit: 4)
        XCTAssertEqual(body, Data([1, 2, 3, 4]))
        XCTAssertEqual(response.statusCode, 200)
    }

    func testOversizedContentLengthIsRejectedWithoutRetry() async throws {
        let calls = LockedRequestCounter()
        fixture.respond = { _ in
            calls.increment()
            return FixtureResponse(headers: ["Content-Length": "1000"], body: Data([1]))
        }
        do {
            _ = try await transport().data(for: URLRequest(url: url), operation: .catalog, byteLimit: 4)
            XCTFail("Oversized response was accepted")
        } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
        XCTAssertEqual(calls.value, 1)
    }

    func testUnknownLengthStopsReceivingWhenChunksExceedLimit() async throws {
        let delivered = LockedRequestCounter(), calls = LockedRequestCounter()
        // CFNetwork coalesces tiny URLProtocol writes; use real transfer-sized chunks
        // so the delegate can reject the body before the fixture finishes sending it.
        let chunk = Data(repeating: 1, count: 64 * 1024)
        fixture.respond = { _ in
            calls.increment()
            var response = FixtureResponse()
            response.chunks = Array(repeating: chunk, count: 100)
            response.chunkInterval = 0.005
            response.onChunk = { delivered.increment() }
            return response
        }
        do {
            _ = try await transport().data(
                for: URLRequest(url: url), operation: .artwork, byteLimit: chunk.count * 2)
            XCTFail("Oversized response was accepted")
        } catch { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
        XCTAssertEqual(calls.value, 1)
        XCTAssertLessThan(delivered.value, 100, "The body must be rejected before the complete transfer")
    }

    func testCancellationDuringBodyDeliveryStopsTheRequest() async throws {
        let started = expectation(description: "First response chunk")
        fixture.respond = { _ in
            var response = FixtureResponse()
            response.chunks = [Data([1]), Data([2])]
            response.chunkInterval = 1
            response.onChunk = { started.fulfill() }
            return response
        }
        let transport = transport(), request = URLRequest(url: url)
        let task = Task { try await transport.data(for: request, operation: .metadata) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled request returned a body")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testIndependentFixturesNeverShareHandlersForTheSameURL() async throws {
        let other = HTTPFixture()
        fixture.handler = { _ in
            Thread.sleep(forTimeInterval: 0.02)
            return (200, Data("first".utf8))
        }
        other.handler = { _ in (200, Data("second".utf8)) }
        let first = transport(),
            second = HTTPTransport(session: other.session(), diagnostics: DiagnosticRecorder())
        let request = URLRequest(url: url)
        async let one = first.data(for: request, operation: .metadata)
        async let two = second.data(for: request, operation: .metadata)
        let values = try await (one, two)
        XCTAssertEqual(String(decoding: values.0.0, as: UTF8.self), "first")
        XCTAssertEqual(String(decoding: values.1.0, as: UTF8.self), "second")
    }
}
