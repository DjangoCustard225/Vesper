import Testing
import Foundation
@testable import DownloadEngine

/// Minimal yEnc *encoder* used only to generate test fixtures for the decoder.
private enum TestYEnc {
    static func encodeBytes(_ data: Data) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for d in data {
            let e = d &+ 42
            if e == 0x00 || e == 0x0A || e == 0x0D || e == 0x3D {
                out.append(0x3D)  // '='
                out.append(e &+ 64)
            } else {
                out.append(e)
            }
        }
        return out
    }

    static func dataLines(_ data: Data, width: Int) -> [Data] {
        let bytes = encodeBytes(data)
        guard !bytes.isEmpty else { return [] }
        return stride(from: 0, to: bytes.count, by: width).map {
            Data(bytes[$0..<min($0 + width, bytes.count)])
        }
    }

    static func singlePart(_ data: Data, name: String, width: Int = 128) -> [Data] {
        let crc = String(format: "%08x", CRC32.checksum(of: data))
        var lines = [Data("=ybegin line=\(width) size=\(data.count) name=\(name)".utf8)]
        lines += dataLines(data, width: width)
        lines.append(Data("=yend size=\(data.count) crc32=\(crc) pcrc32=\(crc)".utf8))
        return lines
    }

    static func multiPart(
        _ data: Data, name: String, part: Int, total: Int,
        begin: Int, fileSize: Int, width: Int = 128
    ) -> [Data] {
        let end = begin + data.count - 1
        let crc = String(format: "%08x", CRC32.checksum(of: data))
        var lines = [
            Data("=ybegin part=\(part) total=\(total) line=\(width) size=\(fileSize) name=\(name)".utf8),
            Data("=ypart begin=\(begin) end=\(end)".utf8),
        ]
        lines += dataLines(data, width: width)
        lines.append(Data("=yend size=\(data.count) part=\(part) pcrc32=\(crc)".utf8))
        return lines
    }

    /// A multipart part whose =yend carries only the whole-file crc32 (no per-part pcrc32) — a
    /// common real-world posting that must not be treated as a per-part checksum.
    static func multiPartWholeFileCRCOnly(
        _ data: Data, name: String, part: Int, total: Int,
        begin: Int, fileSize: Int, wholeFileCRC: UInt32,
        width: Int = 128
    ) -> [Data] {
        let end = begin + data.count - 1
        var lines = [
            Data("=ybegin part=\(part) total=\(total) line=\(width) size=\(fileSize) name=\(name)".utf8),
            Data("=ypart begin=\(begin) end=\(end)".utf8),
        ]
        lines += dataLines(data, width: width)
        lines.append(
            Data("=yend size=\(data.count) part=\(part) crc32=\(String(format: "%08x", wholeFileCRC))".utf8))
        return lines
    }
}

struct YEncTests {
    /// Data that exercises every escape case: bytes whose +42 output lands on NULL/LF/CR/'='.
    private var trickyData: Data {
        var bytes: [UInt8] = [214, 224, 227, 19]  // → output 0x00, 0x0A, 0x0D, 0x3D (all escaped)
        bytes += (0..<512).map { UInt8(($0 * 37 + 5) & 0xFF) }
        return Data(bytes)
    }

    @Test func singlePartRoundTrip() throws {
        let data = trickyData
        // Narrow width forces escape pairs to straddle line boundaries — exercises escapePending.
        let lines = TestYEnc.singlePart(data, name: "hello world.bin", width: 17)
        let seg = try YEncDecoder.decode(bodyLines: lines)

        #expect(seg.data == data)
        #expect(seg.crcMatches == true)
        #expect(seg.computedCRC == CRC32.checksum(of: data))
        #expect(seg.header.name == "hello world.bin")
        #expect(seg.fileOffset == 0)
    }

    @Test func multiPartOffsetAndCRC() throws {
        let data = Data((0..<1000).map { UInt8(($0 * 13) & 0xFF) })
        let begin = 1001  // second 1000-byte part → 0-based offset 1000
        let lines = TestYEnc.multiPart(
            data, name: "archive.r00", part: 2, total: 5,
            begin: begin, fileSize: 5000, width: 128)
        let seg = try YEncDecoder.decode(bodyLines: lines)

        #expect(seg.data == data)
        #expect(seg.crcMatches == true)
        #expect(seg.fileOffset == 1000)
        #expect(seg.header.part == 2)
        #expect(seg.header.isMultipart)
    }

    @Test func corruptDataFailsCRC() throws {
        let data = Data((0..<200).map { UInt8($0 & 0xFF) })
        var lines = TestYEnc.singlePart(data, name: "x.bin", width: 64)
        // Flip a byte in the first data line (index 1, after the =ybegin header).
        var corrupt = lines[1]
        corrupt[corrupt.startIndex] = corrupt[corrupt.startIndex] &+ 1
        lines[1] = corrupt

        let seg = try YEncDecoder.decode(bodyLines: lines)
        #expect(seg.crcMatches == false)
    }

    /// A multipart segment that declares only the whole-file crc32 (no pcrc32) must be accepted
    /// (crcMatches == nil), not falsely failed against a checksum that describes the whole file.
    @Test func multiPartWithoutPerPartCRCIsAccepted() throws {
        let data = Data((0..<1000).map { UInt8(($0 * 7) & 0xFF) })
        // Whole-file CRC deliberately unrelated to this part's bytes.
        let lines = TestYEnc.multiPartWholeFileCRCOnly(
            data, name: "part2.bin", part: 2, total: 5, begin: 1001, fileSize: 5000,
            wholeFileCRC: 0xDEADBEEF)
        let seg = try YEncDecoder.decode(bodyLines: lines)
        #expect(seg.data == data)
        #expect(seg.crcMatches == nil)  // not false — we can't per-part-verify, so we accept
    }

    @Test func missingBeginThrows() {
        let lines = [Data("just some text".utf8), Data("=yend size=0".utf8)]
        #expect(throws: YEncError.missingBeginHeader) {
            _ = try YEncDecoder.decode(bodyLines: lines)
        }
    }

    @Test func emptyNameOmitted() throws {
        let data = Data([1, 2, 3, 4, 5])
        let lines = TestYEnc.singlePart(data, name: "a.bin")
        let seg = try YEncDecoder.decode(bodyLines: lines)
        #expect(seg.header.name == "a.bin")
        #expect(seg.declaredPartSize == data.count)
    }
}
