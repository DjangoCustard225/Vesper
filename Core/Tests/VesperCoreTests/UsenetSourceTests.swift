import XCTest
@testable import VesperCore

final class UsenetSourceTests: XCTestCase {
    private func source(_ json: String) throws -> StreamSource {
        try JSONDecoder().decode(StreamSource.self, from: Data(json.utf8))
    }
    func testNZBSourceRoutesToUsenetAndCredentialsAreNotSerialized() throws {
        let stream = try source(
            #"{"nzbUrl":"https://addon.example/file.nzb","servers":["nntps://user:private-password@news.example:563/4"],"fileIdx":1,"fileMustInclude":"/.mkv$/i"}"#
        )
        XCTAssertEqual(try StreamResolver.resolve(stream), .usenet)
        XCTAssertEqual(stream.servers?.count, 1)
        let saved = try JSONEncoder().encode(stream), json = String(decoding: saved, as: UTF8.self)
        XCTAssertFalse(json.contains("servers")); XCTAssertFalse(json.contains("private-password"))
        XCTAssertEqual(try JSONDecoder().decode(StreamSource.self, from: saved).nzbUrl, stream.nzbUrl)
        XCTAssertThrowsError(try DownloadPolicy.url(for: stream))
    }
    func testNZBFileSelectionAffectsIdentityAndFreshLinkMatching() throws {
        let one = try source(#"{"nzbUrl":"https://addon.example/file.nzb?token=old","fileIdx":1}"#)
        let two = try source(#"{"nzbUrl":"https://addon.example/file.nzb?token=new","fileIdx":1}"#)
        let wrong = try source(#"{"nzbUrl":"https://addon.example/file.nzb?token=new","fileIdx":2}"#)
        XCTAssertNotEqual(StreamPolicy.identity(two), StreamPolicy.identity(wrong))
        XCTAssertEqual(StreamPolicy.refreshedMatch(for: one, in: [wrong, two])?.nzbUrl, two.nzbUrl)
        XCTAssertNil(StreamPolicy.refreshedMatch(for: one, in: [wrong]))
        XCTAssertFalse(StreamPolicy.isPlayable(try source(#"{"nzbUrl":"file:///private/test.nzb"}"#)))
        XCTAssertFalse(StreamPolicy.isPlayable(try source(#"{"nzbUrl":"ftp://example/test.nzb"}"#)))
    }
}
