import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class LockedRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    @discardableResult func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1; return count
    }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class ArtworkDataTests: XCTestCase {
    private let url = URL(string: "https://images.example/original/episode.jpg")!
    private func client(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> ArtworkDataClient {
        FixtureURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return ArtworkDataClient(session: URLSession(configuration: configuration))
    }
    override func tearDown() { FixtureURLProtocol.handler = nil; super.tearDown() }

    func testConcurrentArtworkRequestsAndRevisitsUseOneUnmodifiedDownload() async throws {
        let calls = LockedRequestCounter()
        let original = Data((0..<500_000).map { UInt8($0 % 251) })
        let url = url
        let client = client { request in
            calls.increment(); XCTAssertEqual(request.url, url)
            Thread.sleep(forTimeInterval: 0.03)
            return (200, original)
        }
        async let first = client.data(for: url)
        async let second = client.data(for: url)
        let images = try await (first, second)
        XCTAssertEqual(images.0, original); XCTAssertEqual(images.1, original)
        let revisit = try await client.data(for: url)
        XCTAssertEqual(revisit, original)
        XCTAssertEqual(calls.value, 1)
    }
    func testFailedArtworkIsNotCachedAndCanBeRetried() async throws {
        let calls = LockedRequestCounter()
        let client = client { _ in
            let attempt = calls.increment()
            return attempt <= 3 ? (503, Data("failure".utf8)) : (200, Data([1, 2, 3]))
        }
        do { _ = try await client.data(for: url); XCTFail("HTTP failure accepted") }
        catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
        let retry = try await client.data(for: url)
        let cached = try await client.data(for: url)
        XCTAssertEqual(retry, Data([1, 2, 3])); XCTAssertEqual(cached, retry)
        XCTAssertEqual(calls.value, 4)
    }
    func testCancellingOneViewDoesNotCancelAnotherViewsArtwork() async throws {
        let calls = LockedRequestCounter()
        let started = expectation(description: "Artwork request started")
        let original = Data([1, 2, 3, 4])
        let client = client { _ in
            calls.increment(); started.fulfill()
            Thread.sleep(forTimeInterval: 0.05)
            return (200, original)
        }
        let first = Task { try await client.data(for: url) }
        await fulfillment(of: [started], timeout: 2)
        let second = Task { try await client.data(for: url) }
        for _ in 0..<100 {
            if await client.subscriberCount(for: url) == 2 { break }
            await Task.yield()
        }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled view received artwork") }
        catch { XCTAssertTrue(error is CancellationError) }
        let image = try await second.value
        XCTAssertEqual(image, original); XCTAssertEqual(calls.value, 1)
    }
    func testUnsupportedArtworkProtocolsNeverReachTheNetwork() async throws {
        let client = client { _ in XCTFail("Unexpected artwork request"); return (200, Data([1])) }
        do { _ = try await client.data(for: URL(string: "file:///tmp/private")!); XCTFail("Local URL accepted") }
        catch { XCTAssertEqual(error as? AddonError, .invalidURL) }
    }
}
