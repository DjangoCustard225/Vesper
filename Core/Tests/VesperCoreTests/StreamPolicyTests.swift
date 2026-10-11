import XCTest
@testable import VesperCore

final class StreamPolicyTests: XCTestCase {
    private func source(_ json: String) throws -> StreamSource { try JSONDecoder().decode(StreamSource.self, from: Data(json.utf8)) }
    func testDuplicateSourcesIgnoreLabelsButPreserveDifferentAuthenticationAndFiles() throws {
        let first = try source(#"{"name":"A","url":"https://video.example/movie?token=one"}"#)
        let second = try source(#"{"name":"B","url":"https://video.example/movie?token=one"}"#)
        let different = try source(#"{"url":"https://video.example/movie?token=two"}"#)
        XCTAssertEqual(StreamPolicy.unique([first, second, different]).count, 2)
        let torrent = try source(#"{"infoHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileIdx":1}"#)
        let anotherFile = try source(#"{"infoHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileIdx":2}"#)
        XCTAssertNotEqual(StreamPolicy.identity(torrent), StreamPolicy.identity(anotherFile))
    }
    func testUnsupportedSourcesAreDetectedBeforePlayerHandoff() throws {
        XCTAssertFalse(StreamPolicy.isPlayable(try source(#"{"infoHash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#)))
        XCTAssertFalse(StreamPolicy.isPlayable(try source(#"{"url":"file:///private/video"}"#)))
        XCTAssertFalse(StreamPolicy.isPlayable(try source(#"{"url":"https://video.example","behaviorHints":{"proxyHeaders":{"request":{"Authorization":"Bearer x"}}}}"#)))
        XCTAssertTrue(StreamPolicy.isPlayable(try source(#"{"url":"https://video.example/movie.m3u8?signature=signed"}"#)))
    }
    func testOldAndNearlyExpiredSourcesRefreshBeforePlayback() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let video = try source(#"{"url":"https://video.example/movie?expires=1800000010"}"#)
        XCTAssertTrue(StreamPolicy.needsRefresh(video, fetchedAt: now, now: now))
        let plain = try source(#"{"url":"https://video.example/movie"}"#)
        XCTAssertFalse(StreamPolicy.needsRefresh(plain, fetchedAt: now.addingTimeInterval(-89), now: now))
        XCTAssertTrue(StreamPolicy.needsRefresh(plain, fetchedAt: now.addingTimeInterval(-90), now: now))
    }
    func testRefreshedSignedURLNeverSubstitutesAnotherFileOrAmbiguousResult() throws {
        let old = try source(#"{"name":"1080p","url":"https://video.example/stream?file=one&token=old&expires=1800000000"}"#)
        let fresh = try source(#"{"name":"1080p","url":"https://video.example/stream?expires=1900000000&token=new&file=one"}"#)
        let wrong = try source(#"{"name":"1080p","url":"https://video.example/stream?file=two&token=new"}"#)
        XCTAssertEqual(StreamPolicy.refreshedMatch(for: old, in: [wrong, fresh])?.url, fresh.url)
        XCTAssertNil(StreamPolicy.refreshedMatch(for: old, in: [wrong]))
        let alternate = try source(#"{"name":"1080p","url":"https://video.example/stream?file=one&token=other"}"#)
        XCTAssertNil(StreamPolicy.refreshedMatch(for: old, in: [fresh, alternate]))
    }
    func testPlaybackRefreshesOldLinkAndRejectsExpiredOrMissingReplacement() async throws {
        let old = try source(#"{"url":"https://video.example/movie.mkv?token=old"}"#)
        let fresh = try source(#"{"url":"https://video.example/movie.mkv?token=new"}"#)
        let calls = LockedRequestCounter()
        let result = try await StreamPolicy.freshSource(old, fetchedAt: Date().addingTimeInterval(-100)) {
            calls.increment(); return [fresh]
        }
        XCTAssertEqual(result.url, fresh.url); XCTAssertEqual(calls.value, 1)
        let immediate = try await StreamPolicy.freshSource(fresh, fetchedAt: Date()) {
            XCTFail("Fresh links should not trigger a provider request"); return []
        }
        XCTAssertEqual(immediate.url, fresh.url)
        do {
            _ = try await StreamPolicy.freshSource(old, fetchedAt: Date().addingTimeInterval(-100)) { [] }
            XCTFail("Missing source should require another selection")
        } catch { XCTAssertTrue(error is PlaybackError) }
        let expired = try source(#"{"url":"https://video.example/movie.mkv?token=new&expires=1000000001"}"#)
        do {
            _ = try await StreamPolicy.freshSource(old, fetchedAt: Date().addingTimeInterval(-100)) { [expired] }
            XCTFail("Expired replacement accepted")
        } catch { XCTAssertTrue(error is PlaybackError) }
    }
}
