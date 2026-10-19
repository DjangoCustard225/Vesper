import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SessionOwnershipTests: XCTestCase {
    private let fixture = HTTPFixture()

    func testReleasingAddonClientLeavesBorrowedSessionUsable() async throws {
        try await checkBorrowedSession { AddonClient(session: $0) }
    }

    func testReleasingTMDBClientLeavesBorrowedSessionUsable() async throws {
        try await checkBorrowedSession { TMDBClient(session: $0) }
    }

    func testReleasingTVDBClientLeavesBorrowedSessionUsable() async throws {
        try await checkBorrowedSession { TVDBClient(session: $0) }
    }

    func testReleasingArtworkClientLeavesBorrowedSessionUsable() async throws {
        try await checkBorrowedSession { ArtworkDataClient(session: $0) }
    }

    private func checkBorrowedSession(_ makeClient: (URLSession) -> AnyObject) async throws {
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        fixture.handler = { _ in (200, Data("available".utf8)) }
        weak var released: AnyObject?
        do {
            let client = makeClient(session)
            released = client
        }
        XCTAssertNil(released)
        let (data, response) = try await session.data(
            for: fixture.request(URL(string: "https://provider.example/health")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "available")
    }
}
