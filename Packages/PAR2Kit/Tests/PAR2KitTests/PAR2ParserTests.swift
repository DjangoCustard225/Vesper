import Testing
import Foundation
@testable import PAR2Kit

/// The PAR2 parser runs on `.par2` files downloaded from Usenet — i.e. untrusted bytes. It must
/// never trap or hang, only reject.
struct PAR2ParserTests {
    private func write(_ bytes: [UInt8]) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("par2test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("hostile.par2")
        try? Data(bytes).write(to: url)
        return url
    }

    @Test func garbageBytesProduceNoValidSet() {
        let url = write((0..<4096).map { UInt8(($0 * 31 + 7) & 0xFF) })
        let job = PAR2Job(par2URLs: [url], directory: url.deletingLastPathComponent())
        #expect(!job.hasPar2)
        #expect(job.verify().isComplete == true || job.verify().hasPar2 == false)
    }

    /// A packet whose declared length is UInt64.max must be rejected, not trap the Int conversion
    /// or overflow the offset arithmetic.
    @Test func absurdPacketLengthDoesNotCrash() {
        var bytes = Array("PAR2\0PKT".utf8)  // magic
        bytes += [UInt8](repeating: 0xFF, count: 8)  // length = UInt64.max
        bytes += [UInt8](repeating: 0, count: 48)  // md5 + recoverySetID + type padding
        let url = write(bytes)
        let job = PAR2Job(par2URLs: [url], directory: url.deletingLastPathComponent())
        #expect(!job.hasPar2)  // reached without trapping
    }

    @Test func emptyFileIsHandled() {
        let url = write([])
        let job = PAR2Job(par2URLs: [url], directory: url.deletingLastPathComponent())
        #expect(!job.hasPar2)
    }

    @Test func truncatedMagicIsIgnored() {
        let url = write(Array("PAR2\0PK".utf8))  // 7 bytes, shorter than the 8-byte magic
        let job = PAR2Job(par2URLs: [url], directory: url.deletingLastPathComponent())
        #expect(!job.hasPar2)
    }
}
