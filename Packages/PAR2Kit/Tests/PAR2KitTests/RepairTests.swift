import Testing
import Foundation
import CryptoKit
@testable import PAR2Kit

/// End-to-end repair through `PAR2Job`. This is the only path that reads recovery slices, and the
/// parser records where they live rather than loading them, so an offset that is wrong by one byte
/// shows up here as a failed repair and nowhere else.
struct RepairTests {
    private let sliceSize = 4

    // MARK: - Minimal PAR2 writer (Main + FileDescription + IFSC + RecoverySlice)

    private func packet(type: String, body: [UInt8], setID: [UInt8]) -> [UInt8] {
        var typeField = Array(type.utf8)
        typeField += [UInt8](repeating: 0, count: 16 - typeField.count)
        let signed = setID + typeField + body
        let length = UInt64(64 + body.count)
        var bytes = Array("PAR2\0PKT".utf8)
        bytes += (0..<8).map { UInt8((length >> (8 * UInt64($0))) & 0xFF) }
        bytes += Array(Insecure.MD5.hash(data: Data(signed)))
        bytes += signed
        return bytes
    }

    private func u64(_ value: Int) -> [UInt8] {
        (0..<8).map { UInt8((UInt64(value) >> (8 * UInt64($0))) & 0xFF) }
    }
    private func u32(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8((UInt32(value) >> (8 * UInt32($0))) & 0xFF) }
    }

    private func words(_ bytes: [UInt8]) -> [UInt16] {
        stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
    }
    private func bytes(_ words: [UInt16]) -> [UInt8] {
        words.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    @Test func repairsADamagedBlockFromRecoveryDataReadOnDemand() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("par2-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let content: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let fileURL = dir.appendingPathComponent("payload.bin")
        let blocks = [Array(content[0..<4]), Array(content[4..<8])]

        // One recovery block: R = Σ base_i^e · D_i, with the base logarithms PAR2Job assigns to
        // input blocks 0 and 1 (the first two integers coprime to 65535).
        let baseLogs = [1, 2]
        let exponent = 1
        var recovery = [UInt16](repeating: 0, count: sliceSize / 2)
        for (i, block) in blocks.enumerated() {
            let coeff = GaloisField16.antilog((baseLogs[i] * exponent) % GaloisField16.limit)
            ReedSolomon.addScaled(&recovery, words(block), coeff)
        }

        let setID = [UInt8](repeating: 0xAB, count: 16)
        let fileID = [UInt8](repeating: 0x11, count: 16)
        var name = Array("payload.bin".utf8)
        while name.count % 4 != 0 { name.append(0) }  // packets are 4-byte aligned
        let md5 = Array(Insecure.MD5.hash(data: Data(content)))  // file is under 16 KB, so also the 16k hash

        var par2 = packet(type: "PAR 2.0\0Main", body: u64(sliceSize) + u32(1) + fileID, setID: setID)
        par2 += packet(
            type: "PAR 2.0\0FileDesc",
            body: fileID + md5 + md5 + u64(content.count) + name, setID: setID)
        var ifsc = fileID
        for block in blocks { ifsc += Array(Insecure.MD5.hash(data: Data(block))) + u32(0) }
        par2 += packet(type: "PAR 2.0\0IFSC", body: ifsc, setID: setID)
        par2 += packet(type: "PAR 2.0\0RecvSlic", body: u32(exponent) + bytes(recovery), setID: setID)

        let par2URL = dir.appendingPathComponent("recovery.par2")
        try Data(par2).write(to: par2URL)

        // Damage the second block.
        try Data(blocks[0] + [0xFF, 0xFF, 0xFF, 0xFF]).write(to: fileURL)

        let job = PAR2Job(par2URLs: [par2URL], directory: dir)
        #expect(job.verify().missingSlices == 1)
        #expect(job.verify().recoveryBlocksAvailable == 1)
        #expect(job.repair() == .repaired(blocks: 1))
        #expect(try Data(contentsOf: fileURL) == Data(content))
    }

    @Test func reportsRecoveryDataThatNoLongerHashesToItsPacket() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("par2-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let content: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let fileURL = dir.appendingPathComponent("payload.bin")
        let blocks = [Array(content[0..<4]), Array(content[4..<8])]
        let setID = [UInt8](repeating: 0xAB, count: 16)
        let fileID = [UInt8](repeating: 0x11, count: 16)
        var name = Array("payload.bin".utf8)
        while name.count % 4 != 0 { name.append(0) }
        let md5 = Array(Insecure.MD5.hash(data: Data(content)))

        var par2 = packet(type: "PAR 2.0\0Main", body: u64(sliceSize) + u32(1) + fileID, setID: setID)
        par2 += packet(
            type: "PAR 2.0\0FileDesc",
            body: fileID + md5 + md5 + u64(content.count) + name, setID: setID)
        var ifsc = fileID
        for block in blocks { ifsc += Array(Insecure.MD5.hash(data: Data(block))) + u32(0) }
        par2 += packet(type: "PAR 2.0\0IFSC", body: ifsc, setID: setID)
        par2 += packet(type: "PAR 2.0\0RecvSlic", body: u32(1) + [0, 0, 0, 0], setID: setID)

        // Corrupt the recovery payload after the packet MD5 was computed over it. The parser skips
        // that MD5 now, so this has to be caught at read time.
        let corruptedAt = par2.count - 1
        par2[corruptedAt] ^= 0xFF

        let par2URL = dir.appendingPathComponent("recovery.par2")
        try Data(par2).write(to: par2URL)
        try Data(blocks[0] + [0xFF, 0xFF, 0xFF, 0xFF]).write(to: fileURL)

        let job = PAR2Job(par2URLs: [par2URL], directory: dir)
        #expect(job.repair() == .failed(reason: "A recovery block is unreadable or damaged."))
    }
}
