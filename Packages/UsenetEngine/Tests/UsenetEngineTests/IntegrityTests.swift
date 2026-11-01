import Foundation
import XCTest
@testable import UsenetEngine

final class IntegrityTests: XCTestCase {
    func testYEncRoundTripsEveryByteAndVerifiesOffsetsAndCRC() throws {
        let data = Data((0...255).map(UInt8.init))
        let decoded = try YEncDecoder.decode(
            bodyLines: encoded(data, offset: 1000, size: 2000, part: 2, total: 3))
        XCTAssertEqual(decoded.data, data); XCTAssertEqual(decoded.fileOffset, 1000);
        XCTAssertEqual(decoded.crcMatches, true)
    }
    func testYEncRejectsTruncationInvalidOffsetsWrongSizesAndCRC() {
        let good = encoded(Data([1, 2, 3]))
        var badCRC = good; badCRC[badCRC.count - 1] = Data("=yend size=3 pcrc32=12345678".utf8)
        var badOffset = good; badOffset[1] = Data("=ypart begin=0 end=2".utf8)
        var hugeOffset = good;
        hugeOffset[1] = Data("=ypart begin=9223372036854775807 end=9223372036854775807".utf8)
        var badSize = good; badSize[badSize.count - 1] = Data("=yend size=100".utf8)
        var escape = good; escape[2] = Data([61])
        for value in [Array(good.dropLast()), badCRC, badOffset, hugeOffset, badSize, escape] {
            XCTAssertThrowsError(try YEncDecoder.decode(bodyLines: value))
        }
    }
    func testNZBParsesCompleteDocumentAndRejectsBrokenStructures() throws {
        func xml(_ body: String) -> Data { Data("<nzb>\(body)</nzb>".utf8) }
        let file =
            "<file subject='&quot;movie.mp4&quot; yEnc'><segments><segment bytes='200' number='1'>one@example</segment></segments></file>"
        let manifest = try NZBManifest.parse(xml(file))
        XCTAssertEqual(manifest.files.first?.name, "movie.mp4");
        XCTAssertEqual(manifest.files.first?.segments.first?.messageID, "one@example")
        for data in [
            Data("<nzb>\(file)".utf8), xml(file.replacingOccurrences(of: "number='1'", with: "number='2'")),
            xml(file.replacingOccurrences(of: "bytes='200'", with: "bytes='-1'")),
            xml("<head>\(file)</head>"), xml(file.replacingOccurrences(of: "one@example", with: "bad id")),
            Data("<wrapper>\(String(decoding:xml(file),as:UTF8.self))</wrapper>".utf8),
            Data("<!DOCTYPE nzb [<!ENTITY x 'value'>]><nzb>\(file)</nzb>".utf8),
        ] {
            XCTAssertThrowsError(try NZBManifest.parse(data), String(decoding: data, as: UTF8.self))
        }
    }
    func testProviderConnectionLimitsIncludeOneHundred() throws {
        var provider = UsenetProvider(
            host: "news.example.com", username: "user", password: "pass", connections: 100)
        XCTAssertEqual(try provider.validated().connections, 100)
        provider.connections = 101
        XCTAssertThrowsError(try provider.validated())
        provider.connections = 0
        XCTAssertThrowsError(try provider.validated())
        XCTAssertEqual(
            try UsenetProvider.from(server: "nntps://news.example.com/100", limit: 100).connections, 100)
    }
    func testTLSProviderParsesCredentialsAndHonorsLowerConnectionCount() throws {
        let value = try UsenetProvider.from(server: "nntps://u%40x:p%3Ass@news.example.test:563/4", limit: 8)
        XCTAssertEqual(value.username, "u@x"); XCTAssertEqual(value.password, "p:ss");
        XCTAssertEqual(value.connections, 4)
        for raw in [
            "nntp://u:p@host/4", "nntps://u:p@host/0", "nntps://u:p@host/4?secret=1",
            "nntps://u%0aBODY:p@host/4",
        ] { XCTAssertThrowsError(try UsenetProvider.from(server: raw)) }
    }
    func testHTTPRangeSemanticsAndOverflowRejection() throws {
        XCTAssertEqual(try HTTPByteRange.resolve(nil, size: 100).count, 100)
        XCTAssertEqual(try HTTPByteRange.resolve("bytes=10-20", size: 100), HTTPByteRange(start: 10, end: 20))
        XCTAssertEqual(try HTTPByteRange.resolve("bytes=98-", size: 100), HTTPByteRange(start: 98, end: 99))
        XCTAssertEqual(try HTTPByteRange.resolve("bytes=-200", size: 100), HTTPByteRange(start: 0, end: 99))
        XCTAssertEqual(try HTTPByteRange.resolve("bytes=-3", size: 100), HTTPByteRange(start: 97, end: 99))
        for value in [
            "bytes=100-", "bytes=20-10", "bytes=-0", "bytes=0-1,3-4", "bytes=9223372036854775808-",
            "bytes=--1",
        ] { XCTAssertThrowsError(try HTTPByteRange.resolve(value, size: 100)) }
    }
    func testHTTPParserAcceptsHeadAndRejectsDuplicateHeadersAndPost() throws {
        let request = try LocalHTTPRequest(
            Data("HEAD /token/video.mp4 HTTP/1.1\r\nHost: 127.0.0.1:1234\r\nRange: bytes=-2\r\n\r\n".utf8))
        XCTAssertEqual(request.method, "HEAD"); XCTAssertEqual(request.headers["range"], "bytes=-2")
        for value in [
            "GET / HTTP/1.1\r\nHost: a\r\nhost: b\r\n\r\n", "POST / HTTP/1.1\r\n\r\n", "GET / HTTP/1.1\n\n",
        ] { XCTAssertThrowsError(try LocalHTTPRequest(Data(value.utf8))) }
    }
    func testSelectionHonorsIndexAndAddonRegex() throws {
        let videos = [
            UsenetVideo(id: 0, name: "Pilot.MKV", extents: []),
            UsenetVideo(id: 1, name: "Finale.mp4", extents: []),
        ]
        XCTAssertEqual(try UsenetSelection.candidates(videos, fileIndex: 1, pattern: nil), [videos[1]])
        XCTAssertEqual(
            try UsenetSelection.candidates(videos, fileIndex: nil, pattern: "/.mkv$|.mp4$|.avi$|.ts$/i"),
            videos)
        XCTAssertThrowsError(try UsenetSelection.candidates(videos, fileIndex: 10, pattern: nil))
        XCTAssertThrowsError(try UsenetSelection.candidates(videos, fileIndex: nil, pattern: "(a+)+$"))
    }
}
