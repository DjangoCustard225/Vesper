import Foundation
import XCTest
@testable import VesperCore

final class HTTPDownloadTests: XCTestCase {
    private let video = Data([0x1a, 0x45, 0xdf, 0xa3])
    func testStrictRangesRejectMalformedAndUnboundedParts() throws {
        let range = try XCTUnwrap(HTTPContentRange("bytes 4-7/8"))
        XCTAssertEqual(range.lower, 4); XCTAssertEqual(range.upper, 7)
        XCTAssertEqual(range.total, 8); XCTAssertEqual(range.count, 4)
        for value in [
            "bytes */8", "bytes 0-7/*", "bytes 8-7/9", "bytes 0-8/8", "bytes -1-7/8",
            "bytes 0-7/0", "bytes 0-7/9223372036854775808", "bits 0-7/8", "bytes 0-7/8/9",
        ] {
            XCTAssertNil(HTTPContentRange(value), value)
        }
    }
    func testCompletionRequiresFullResumedFileAndConsistentResponse() throws {
        try HTTPDownloadPolicy.validateCompletion(
            status: 206, contentRange: "bytes 4-7/8",
            contentLength: 4, actualBytes: 8, mime: "video/x-matroska", prefix: video)
        for (range, length, bytes) in [
            ("bytes 4-7/8", Int64(4), Int64(4)),
            ("bytes 0-3/8", 4, 8), ("bytes 4-7/8", 8, 8),
        ] {
            XCTAssertThrowsError(
                try HTTPDownloadPolicy.validateCompletion(
                    status: 206,
                    contentRange: range, contentLength: length, actualBytes: bytes, mime: nil, prefix: video))
        }
        XCTAssertThrowsError(
            try HTTPDownloadPolicy.validateCompletion(
                status: 206,
                contentRange: "bytes 0-7/8", contentLength: 8, actualBytes: 8, encoding: "gzip", mime: nil,
                prefix: video))
        XCTAssertThrowsError(
            try HTTPDownloadPolicy.validateCompletion(
                status: 200,
                contentRange: nil, contentLength: 9, actualBytes: 8, mime: nil, prefix: video))
        XCTAssertThrowsError(
            try HTTPDownloadPolicy.validateCompletion(
                status: 200,
                contentRange: nil, contentLength: 8, actualBytes: 8, mime: "text/html",
                prefix: Data("<html>".utf8)))
    }
    func testRetryBudgetAndServerDelay() throws {
        XCTAssertEqual(
            HTTPDownloadPolicy.retryDelay(status: 503, code: nil, retryAfter: "120", attempt: 1), 120)
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            HTTPDownloadPolicy.retryDelay(
                status: 429, code: nil,
                retryAfter: "Thu, 01 Jan 1970 00:02:00 GMT", attempt: 1, now: now), 120)
        XCTAssertEqual(
            HTTPDownloadPolicy.retryDelay(
                status: nil, code: NSURLErrorTimedOut,
                retryAfter: nil, attempt: 1, jitter: 0.5), 4.5)
        for status in [400, 401, 403, 404, 416] {
            XCTAssertNil(
                HTTPDownloadPolicy.retryDelay(
                    status: status, code: NSURLErrorTimedOut,
                    retryAfter: nil, attempt: 1))
        }
        XCTAssertNil(HTTPDownloadPolicy.retryDelay(status: 503, code: nil, retryAfter: nil, attempt: 5))
        XCTAssertNil(HTTPDownloadPolicy.retryDelay(status: 503, code: nil, retryAfter: "9999999", attempt: 1))
    }
    func testResumeRecoveryIsBounded() {
        XCTAssertTrue(
            HTTPDownloadPolicy.shouldRestartResume(
                code: NSURLErrorCannotOpenFile,
                status: nil, wasResuming: true, recoveries: 0))
        XCTAssertFalse(
            HTTPDownloadPolicy.shouldRestartResume(
                code: NSURLErrorCannotOpenFile,
                status: nil, wasResuming: false, recoveries: 0))
        XCTAssertFalse(
            HTTPDownloadPolicy.shouldRestartResume(
                code: nil, status: 416,
                wasResuming: true, recoveries: 1))
    }
    func testRangeIdentityPreservesFileAndValidators() throws {
        let size = HTTPDownloadPolicy.minimumParallelSize
        let original = try XCTUnwrap(
            HTTPRangeIdentity(
                sourceURL: "https://files.example/video?id=1&token=old", etag: "\"one\"", total: size))
        XCTAssertEqual(
            original,
            HTTPRangeIdentity(
                sourceURL: "https://files.example/video?id=1&token=new", etag: "\"one\"", total: size))
        XCTAssertNotEqual(
            original,
            HTTPRangeIdentity(
                sourceURL: "https://files.example/video?id=2&token=new", etag: "\"one\"", total: size))
        XCTAssertNotEqual(
            original,
            HTTPRangeIdentity(sourceURL: "https://files.example/video?id=1", etag: "\"two\"", total: size))
        XCTAssertNil(
            HTTPRangeIdentity(sourceURL: "https://files.example/video", etag: "W/\"one\"", total: size))
        XCTAssertNil(
            HTTPRangeIdentity(sourceURL: "https://files.example/video", etag: "\"one\"", total: size - 1))
        let ranges = HTTPDownloadPolicy.ranges(total: size + 123)
        XCTAssertEqual(ranges.first?.lowerBound, 0); XCTAssertEqual(ranges.last?.upperBound, size + 123)
        XCTAssertEqual(ranges.reduce(Int64(0)) { $0 + Int64($1.count) }, size + 123)
        for pair in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound) }
    }
}
