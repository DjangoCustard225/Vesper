import Foundation
import XCTest
@testable import VesperCore

final class DownloadWorkProgressTests: XCTestCase {
    func testStagesReserveCompletionForTheCommittedFile() {
        let stages: [DownloadWorkProgress.Stage] = [.verifying, .repairing, .extracting, .saving]
        var previous: Int64 = 0
        for stage in stages {
            let start = DownloadWorkProgress(stage).units
            let end = DownloadWorkProgress(stage, fraction: 1).units
            XCTAssertGreaterThanOrEqual(start, previous)
            XCTAssertLessThan(end, 1_000_000)
            XCTAssertGreaterThan(end, start)
            previous = end
        }
        XCTAssertEqual(DownloadWorkProgress(.saving, fraction: .nan).fraction, 0)
        XCTAssertEqual(DownloadWorkProgress(.saving, fraction: 2).fraction, 1)
        XCTAssertGreaterThan(DownloadWorkProgress(.assembling, fraction: 1).units, 900_000)
    }
}
