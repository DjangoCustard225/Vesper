import Testing
import Foundation
@testable import DownloadEngine

struct CRC32Tests {
    @Test func standardCheckVector() {
        // The canonical CRC-32 check value for "123456789" is 0xCBF43926.
        let data = Data("123456789".utf8)
        #expect(CRC32.checksum(of: data) == 0xCBF4_3926)
    }

    @Test func emptyIsZero() {
        #expect(CRC32.checksum(of: Data()) == 0)
    }

    @Test func incrementalMatchesOneShot() {
        let full = Data((0..<1000).map { UInt8($0 & 0xFF) })
        var inc = CRC32()
        inc.update(full.prefix(400))
        inc.update(full.suffix(from: full.index(full.startIndex, offsetBy: 400)))
        #expect(inc.checksum == CRC32.checksum(of: full))
    }
}
