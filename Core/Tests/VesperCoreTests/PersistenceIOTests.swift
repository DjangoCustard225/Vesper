import XCTest
@testable import VesperCore

final class PersistenceIOTests: XCTestCase {
    func testBoundedReadAcceptsLimitAndRejectsOversizedFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try PersistenceIO.write(Data(repeating: 42, count: 10), file)
        XCTAssertEqual(try PersistenceIO.read(file, maximumBytes: 10).count, 10)
        XCTAssertThrowsError(try PersistenceIO.read(file, maximumBytes: 9)) {
            XCTAssertTrue($0 is PersistenceIO.ReadError)
        }
    }

    func testMissingFileRetainsUnderlyingReadError() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try PersistenceIO.read(file, maximumBytes: 10)) {
            XCTAssertFalse($0 is PersistenceIO.ReadError)
        }
    }
}
