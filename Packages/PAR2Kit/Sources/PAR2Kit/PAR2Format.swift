//
//  PAR2Format.swift
//  PAR2Kit
//
//  Clean-room PAR2 packet parser + recovery-set aggregation. Parses the packets out of one or
//  more `.par2` files, validates each packet's MD5, and collapses the (heavily duplicated)
//  packets into a single coherent recovery set.
//

import Foundation
import CryptoKit

// MARK: - Little-endian byte helpers

private extension Array where Element == UInt8 {
    func u32LE(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(
            self[offset + 3]) << 24
    }
    func u64LE(_ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[offset + i]) << (8 * i) }
        return v
    }
}

private extension UnsafeRawBufferPointer {
    func u32LE(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(
            self[offset + 3]) << 24
    }
    func u64LE(_ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[offset + i]) << (8 * i) }
        return v
    }
}

// MARK: - Packets

enum PAR2PacketType {
    case main, fileDescription, inputSliceChecksum, recoverySlice, creator, unknown
}

struct PAR2Packet {
    let type: PAR2PacketType
    let recoverySetID: [UInt8]  // 16 bytes
    let body: [UInt8]  // empty for .recoverySlice — see `slice`
    let slice: PAR2RecoverySlice?
}

enum PAR2Parser {
    static let magic: [UInt8] = Array("PAR2\0PKT".utf8)

    private static let typeMain: [UInt8] = Array("PAR 2.0\0Main\0\0\0\0".utf8)
    private static let typeFileDesc: [UInt8] = Array("PAR 2.0\0FileDesc".utf8)
    private static let typeIFSC: [UInt8] = Array("PAR 2.0\0IFSC\0\0\0\0".utf8)
    private static let typeRecvSlice: [UInt8] = Array("PAR 2.0\0RecvSlic".utf8)
    private static let typeCreator: [UInt8] = Array("PAR 2.0\0Creator\0".utf8)

    /// Parse all valid packets in a `.par2` file (MD5-validated). Defends against hostile
    /// input: the packet length is validated as UInt64 (so an absurd value can't trap the
    /// `Int(_:)` conversion or overflow `i + length`) before anything is read.
    ///
    /// Reads through the mapped bytes in place. Copying the file into a `[UInt8]` here is what
    /// used to get the app killed by iOS: a recovery set for a large release is several GB, and
    /// every packet was then copied again to hash it. Recovery-slice payloads are recorded as
    /// locations and never loaded — repair reads only as many as there are missing blocks, and
    /// checks their MD5 then (a slice that fails it is reported, and repair re-verifies anyway).
    static func parse(_ data: Data, from url: URL) -> [PAR2Packet] {
        var packets: [PAR2Packet] = []
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var i = 0
            let n = bytes.count

            while i + 64 <= n {
                // Find the next magic.
                guard matches(bytes, at: i, magic) else { i += 1; continue }

                let len64 = bytes.u64LE(i + 8)
                // Compare in UInt64 so nothing traps/overflows; only convert once it's known in-range.
                guard len64 >= 64, len64 % 4 == 0, len64 <= UInt64(n - i) else { i += 1; continue }
                let length = Int(len64)
                let type = classify(Array(bytes[(i + 48)..<(i + 64)]))

                // 64 header + 4 exponent, so anything shorter carries no recovery data at all.
                if type == .recoverySlice {
                    if length >= 68 {
                        packets.append(
                            PAR2Packet(
                                type: type,
                                recoverySetID: Array(bytes[(i + 32)..<(i + 48)]),
                                body: [],
                                slice: PAR2RecoverySlice(
                                    exponent: Int(bytes.u32LE(i + 64)),
                                    url: url,
                                    signedOffset: i + 32,
                                    signedCount: length - 32,
                                    payloadCount: length - 68,
                                    md5: Array(bytes[(i + 16)..<(i + 32)]))))
                    }
                    i += length
                    continue
                }

                let hash = Array(bytes[(i + 16)..<(i + 32)])
                let signed = Data(bytes[(i + 32)..<(i + length)])  // recoverySetID + type + body
                guard Array(Insecure.MD5.hash(data: signed)) == hash else { i += 1; continue }

                packets.append(
                    PAR2Packet(
                        type: type,
                        recoverySetID: Array(bytes[(i + 32)..<(i + 48)]),
                        body: Array(bytes[(i + 64)..<(i + length)]),
                        slice: nil))
                i += length
            }
        }
        return packets
    }

    private static func matches(_ bytes: UnsafeRawBufferPointer, at offset: Int, _ pattern: [UInt8]) -> Bool {
        guard offset + pattern.count <= bytes.count else { return false }
        for k in 0..<pattern.count where bytes[offset + k] != pattern[k] { return false }
        return true
    }

    private static func classify(_ type: [UInt8]) -> PAR2PacketType {
        switch type {
        case typeMain: return .main
        case typeFileDesc: return .fileDescription
        case typeIFSC: return .inputSliceChecksum
        case typeRecvSlice: return .recoverySlice
        case typeCreator: return .creator
        default: return .unknown
        }
    }
}

// MARK: - Recovery set model

struct PAR2FileDescription {
    let fileID: [UInt8]  // 16
    let fullMD5: [UInt8]  // 16
    let md5_16k: [UInt8]  // 16
    let length: Int
    let name: String
}

struct PAR2SliceChecksum {
    let md5: [UInt8]  // 16
    let crc32: UInt32
}

/// Where a recovery slice's bytes live, rather than the bytes themselves. A recovery set is
/// routinely gigabytes; repair needs exactly as many slices as there are missing blocks, and
/// verification needs none of them, only the count.
struct PAR2RecoverySlice {
    let exponent: Int
    let url: URL
    let signedOffset: Int  // start of the MD5-covered region (recoverySetID + type + body)
    let signedCount: Int
    let payloadCount: Int  // recovery bytes: the body, minus its 4-byte exponent
    let md5: [UInt8]

    /// Read the recovery bytes, checking the packet MD5 the parser deliberately skipped. Nil if
    /// the file moved, was truncated, or the packet doesn't hash to its own header.
    func read() -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(signedOffset))) != nil,
            let signed = try? handle.read(upToCount: signedCount), signed.count == signedCount,
            Array(Insecure.MD5.hash(data: signed)) == md5
        else { return nil }
        return Array(signed.suffix(payloadCount))
    }
}

/// A fully-assembled recovery set built from all `.par2` files.
struct PAR2RecoverySet {
    var sliceSize: Int = 0
    var recoverySetFileIDs: [[UInt8]] = []  // ordered (from Main packet)
    var fileDescriptions: [[UInt8]: PAR2FileDescription] = [:]  // keyed by fileID
    var sliceChecksums: [[UInt8]: [PAR2SliceChecksum]] = [:]  // keyed by fileID
    var recoverySlices: [PAR2RecoverySlice] = []  // deduped by exponent

    var isValid: Bool { sliceSize > 0 && !recoverySetFileIDs.isEmpty }

    /// Files in recovery-set order, each with its description (skips any missing descriptions).
    var orderedFiles: [PAR2FileDescription] {
        recoverySetFileIDs.compactMap { fileDescriptions[$0] }
    }

    static func build(fromParFiles urls: [URL]) -> PAR2RecoverySet {
        var set = PAR2RecoverySet()
        var seenExponents = Set<Int>()

        // Collect every packet across all files first so we can lock onto a single recovery set.
        // Mapped, not read into memory: the recovery volumes stay on disk, where the only thing
        // that ever needs them is repair.
        var allPackets: [PAR2Packet] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            allPackets.append(contentsOf: PAR2Parser.parse(data, from: url))
        }

        // A directory can legitimately hold more than one PAR2 set; merging packets across sets
        // corrupts the input-block ordering. Lock onto the first Main packet's recovery-set ID and
        // ignore everything that doesn't belong to it.
        guard let mainID = allPackets.first(where: { $0.type == .main })?.recoverySetID else {
            return set
        }

        for packet in allPackets where packet.recoverySetID == mainID {
            switch packet.type {
            case .main where set.sliceSize == 0:
                parseMain(packet.body, into: &set)
            case .main:
                break
            case .fileDescription:
                if let fd = parseFileDescription(packet.body) {
                    set.fileDescriptions[fd.fileID] = fd
                }
            case .inputSliceChecksum:
                parseIFSC(packet.body, into: &set)
            case .recoverySlice:
                if let slice = packet.slice, seenExponents.insert(slice.exponent).inserted {
                    set.recoverySlices.append(slice)
                }
            case .creator, .unknown:
                break
            }
        }
        return set
    }

    /// Upper bound on a PAR2 slice size (guards huge per-slice allocations from hostile input).
    /// Real sets use tens of KB to a few MB; 64 MB is far beyond any legitimate value.
    private static let maxSliceSize = 64 * 1024 * 1024

    private static func parseMain(_ body: [UInt8], into set: inout PAR2RecoverySet) {
        guard body.count >= 12 else { return }
        let rawSlice = body.u64LE(0)
        // Slice size must be a positive multiple of 4 and sane; otherwise leave the set invalid
        // (sliceSize == 0) rather than trapping the Int conversion or allocating gigabytes later.
        guard rawSlice > 0, rawSlice % 4 == 0, rawSlice <= UInt64(maxSliceSize) else { return }
        set.sliceSize = Int(rawSlice)
        let count = Int(body.u32LE(8))
        var offset = 12
        for _ in 0..<count {
            guard offset + 16 <= body.count else { break }
            set.recoverySetFileIDs.append(Array(body[offset..<(offset + 16)]))
            offset += 16
        }
    }

    private static func parseFileDescription(_ body: [UInt8]) -> PAR2FileDescription? {
        guard body.count >= 56 else { return nil }
        let fileID = Array(body[0..<16])
        let fullMD5 = Array(body[16..<32])
        let md5_16k = Array(body[32..<48])
        let length = Int(clamping: body.u64LE(48))  // clamp so an absurd length can't trap
        let nameBytes = Array(body[56...]).prefix { $0 != 0 }
        let name = String(decoding: nameBytes, as: UTF8.self)
        return PAR2FileDescription(
            fileID: fileID, fullMD5: fullMD5, md5_16k: md5_16k, length: length, name: name)
    }

    private static func parseIFSC(_ body: [UInt8], into set: inout PAR2RecoverySet) {
        guard body.count >= 16 else { return }
        let fileID = Array(body[0..<16])
        var checksums: [PAR2SliceChecksum] = []
        var offset = 16
        while offset + 20 <= body.count {
            let md5 = Array(body[offset..<(offset + 16)])
            let crc = body.u32LE(offset + 16)
            checksums.append(PAR2SliceChecksum(md5: md5, crc32: crc))
            offset += 20
        }
        if set.sliceChecksums[fileID] == nil { set.sliceChecksums[fileID] = checksums }
    }
}
