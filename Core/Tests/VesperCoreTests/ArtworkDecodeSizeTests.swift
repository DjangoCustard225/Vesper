import XCTest
@testable import VesperCore

final class ArtworkDecodeSizeTests: XCTestCase {
    func testRetinaTargetsRoundUpAndShareNearbyLayoutSizes() throws {
        let target = try XCTUnwrap(ArtworkDecodeSize(width: 100, height: 150, scale: 3))
        XCTAssertEqual(target.width, 320)
        XCTAssertEqual(target.height, 480)
        XCTAssertEqual(target, ArtworkDecodeSize(width: 101, height: 151, scale: 3))
        XCTAssertEqual(target.maximumPixelSize(sourceWidth: 2000, sourceHeight: 3000), 480)
    }

    func testAspectFillDoesNotUndersizeWideOrTallArtwork() throws {
        let target = try XCTUnwrap(ArtworkDecodeSize(width: 100, height: 150, scale: 3))
        XCTAssertEqual(target.maximumPixelSize(sourceWidth: 2000, sourceHeight: 1000), 960)
        XCTAssertEqual(target.maximumPixelSize(sourceWidth: 1000, sourceHeight: 4000), 1280)
        XCTAssertEqual(target.maximumPixelSize(sourceWidth: 200, sourceHeight: 300), 300)
        XCTAssertNil(target.maximumPixelSize(sourceWidth: 0, sourceHeight: 300))
    }

    func testInvalidOrUnboundedDimensionsUseTheOriginalPath() {
        for value in [0, -1, Double.nan, .infinity, 20_000] {
            XCTAssertNil(ArtworkDecodeSize(width: value, height: 150, scale: 3))
            XCTAssertNil(ArtworkDecodeSize(width: 100, height: value, scale: 3))
        }
        XCTAssertNil(ArtworkDecodeSize(width: 100, height: 150, scale: 0))
        XCTAssertNil(ArtworkDecodeSize(width: 100, height: 150, scale: -1))
    }

    func testTimingDiagnosticsRemainCompatibleWithOlderExportsAndContainNoArtworkIdentity() async throws {
        let old = Data(
            "{\"date\":0,\"operation\":\"artwork\",\"attempt\":1,\"milliseconds\":5,\"outcome\":\"success\"}"
                .utf8)
        let decoded = try JSONDecoder().decode(DiagnosticEvent.self, from: old)
        XCTAssertNil(decoded.artworkStage)
        XCTAssertNil(decoded.isPrefetch)
        let recorder = DiagnosticRecorder()
        await recorder.recordArtwork(.preparation, milliseconds: 12, priority: .visible)
        let exported = try await recorder.export()
        let events = try JSONDecoder().decode([DiagnosticEvent].self, from: exported)
        XCTAssertEqual(events.first?.artworkStage, .preparation)
        XCTAssertEqual(events.first?.milliseconds, 12)
        XCTAssertEqual(events.first?.isPrefetch, false)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("url"))
    }
}
