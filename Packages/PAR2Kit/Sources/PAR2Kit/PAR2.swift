//
//  PAR2.swift
//  PAR2Kit
//
//  Public entry point: verify a set of files against their `.par2` recovery files, and repair
//  missing/damaged blocks via Reed-Solomon. Repair always re-verifies afterward, so a repair
//  that produces wrong bytes is reported as failed rather than silently shipping corruption.
//

import Foundation
import CryptoKit

public struct PAR2FileStatus: Sendable, Equatable {
    public let name: String
    public let exists: Bool
    public let intact: Bool  // full-file MD5 matches
    public let totalSlices: Int
    public let goodSlices: Int
}

public struct PAR2VerifyResult: Sendable, Equatable {
    public let sliceSize: Int
    public let files: [PAR2FileStatus]
    public let totalInputSlices: Int
    public let missingSlices: Int
    public let recoveryBlocksAvailable: Int

    public var isComplete: Bool { missingSlices == 0 && files.allSatisfy(\.intact) }
    public var isRepairable: Bool { missingSlices > 0 && missingSlices <= recoveryBlocksAvailable }
    public var hasPar2: Bool { sliceSize > 0 }
}

public enum PAR2RepairResult: Sendable, Equatable {
    case notNeeded
    case repaired(blocks: Int)
    case insufficientRecoveryData(missing: Int, available: Int)
    case failed(reason: String)
}

public final class PAR2Job {
    private let directory: URL
    private let recoverySet: PAR2RecoverySet
    private let files: [PAR2FileDescription]
    private struct Block { let fileIndex: Int; let localSlice: Int }
    private let blocks: [Block]
    private let baseLogs: [Int]

    public init(par2URLs: [URL], directory: URL) {
        self.directory = directory
        let built = PAR2RecoverySet.build(fromParFiles: par2URLs)
        self.recoverySet = built
        self.files = built.orderedFiles

        var blocks: [Block] = []
        if built.isValid {
            for (fi, fd) in files.enumerated() {
                let count =
                    built.sliceChecksums[fd.fileID]?.count
                    ?? ((fd.length + built.sliceSize - 1) / max(1, built.sliceSize))
                for s in 0..<count { blocks.append(Block(fileIndex: fi, localSlice: s)) }
            }
        }
        self.blocks = blocks

        // Input-block base logarithms: integers coprime to 65535, in order (par2's SetInput rule).
        var logs: [Int] = []
        var logbase = 0
        for _ in 0..<blocks.count {
            while GaloisField16.gcd(GaloisField16.limit, logbase) != 1 { logbase += 1 }
            logs.append(logbase)
            logbase += 1
        }
        self.baseLogs = logs
    }

    public var hasPar2: Bool { recoverySet.isValid }

    /// Resolve a PAR2 file-description name to a URL that is guaranteed to stay inside the working
    /// directory. Names come from untrusted PAR2 packets, so collapse any path structure to a
    /// single component (defeating "../" traversal that could otherwise read or overwrite files
    /// outside the download folder during repair).
    private func fileURL(for name: String) -> URL {
        var component = (name as NSString).lastPathComponent
        if component.isEmpty || component == "." || component == ".." { component = "recovered.bin" }
        return directory.appendingPathComponent(component)
    }

    // MARK: - Filename restoration

    /// PAR2 file descriptions carry the real filenames plus a checksum of the first 16 KB, so they
    /// are ground truth. The names files actually land under are not: they come from the article's
    /// yEnc header or the NZB subject, and Usenet posts routinely obfuscate one or mangle the other
    /// (an unquoted subject "A. B - Title.epub (1/0)" parses down to "A."). A misnamed file makes
    /// verify report every slice of perfectly good data as missing.
    ///
    /// So match by content instead of by name: for each description whose file is absent, adopt the
    /// unclaimed file whose length and first-16 KB MD5 agree with it. Returns the renames done.
    @discardableResult
    public func restoreNames() -> [(from: String, to: String)] {
        guard recoverySet.isValid else { return [] }
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        // Never steal a file that is itself some description's correctly-named output.
        var claimed = Set(files.map { fileURL(for: $0.name).lastPathComponent })
        var renames: [(from: String, to: String)] = []

        for fd in files {
            let target = fileURL(for: fd.name)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            let match = contents.first { url in
                !Self.isPar2File(url)
                    && !claimed.contains(url.lastPathComponent)
                    && ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int)
                        == fd.length
                    && Self.md5OfFirst16k(url) == fd.md5_16k
            }
            guard let match, (try? FileManager.default.moveItem(at: match, to: target)) != nil else {
                continue
            }
            claimed.insert(target.lastPathComponent)
            renames.append((from: match.lastPathComponent, to: target.lastPathComponent))
        }
        return renames
    }

    /// A recovery file itself is never a rename candidate. Checked by packet magic as well as by
    /// extension, because obfuscated posts deliver `.par2` files under extension-less hash names.
    private static func isPar2File(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "par2" { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8)) == Data("PAR2\0PKT".utf8)
    }

    /// The PAR2 "16k hash": MD5 of the first 16 KB, or of the whole file when it is smaller.
    private static func md5OfFirst16k(_ url: URL) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 16 * 1024) else { return nil }
        return Array(Insecure.MD5.hash(data: chunk))
    }

    // MARK: - Verify

    public func verify() -> PAR2VerifyResult {
        verify { _ in }
    }

    /// Throw from progress to interrupt verification between slices without discarding payload files.
    public func verify(progress: (Double) throws -> Void) rethrows -> PAR2VerifyResult {
        try verifyDetailed(progress: progress).result
    }

    private func verifyDetailed(progress: (Double) throws -> Void) rethrows -> (
        result: PAR2VerifyResult, presence: [Bool]
    ) {
        try progress(0)
        guard recoverySet.isValid else {
            return (
                PAR2VerifyResult(
                    sliceSize: 0, files: [], totalInputSlices: 0,
                    missingSlices: 0, recoveryBlocksAvailable: 0), []
            )
        }
        var presence = [Bool](repeating: false, count: blocks.count)
        var statuses: [PAR2FileStatus] = []
        var missing = 0
        var globalIndex = 0

        for (fi, fd) in files.enumerated() {
            try progress(Double(globalIndex) / Double(max(1, blocks.count)))
            let expected = blocks.filter { $0.fileIndex == fi }.count
            let checks = recoverySet.sliceChecksums[fd.fileID] ?? []
            let url = fileURL(for: fd.name)
            var good = 0
            var intact = false

            if FileManager.default.fileExists(atPath: url.path),
                let handle = try? FileHandle(forReadingFrom: url)
            {
                defer { try? handle.close() }
                var fullMD5 = Insecure.MD5()
                for local in 0..<expected {
                    try progress(Double(globalIndex + local) / Double(max(1, blocks.count)))
                    if Task.isCancelled { break }
                    // One pool per slice. FileHandle is NSFileHandle underneath and hands back
                    // autoreleased storage, and this loop runs synchronously inside a detached
                    // task, so without a pool of its own it holds the whole file by the end. That
                    // is every byte of the download, not just the recovery set.
                    autoreleasepool {
                        let chunk = readFully(handle, count: recoverySet.sliceSize)
                        fullMD5.update(data: chunk)
                        var slice = chunk
                        if slice.count < recoverySet.sliceSize {
                            slice.append(Data(repeating: 0, count: recoverySet.sliceSize - slice.count))
                        }
                        let md5 = Array(Insecure.MD5.hash(data: slice))
                        let isGood = local < checks.count && md5 == checks[local].md5
                        presence[globalIndex + local] = isGood
                        if isGood { good += 1 } else { missing += 1 }
                    }
                }
                intact = Array(fullMD5.finalize()) == fd.fullMD5
            } else {
                missing += expected  // whole file missing → all slices missing
            }

            statuses.append(
                PAR2FileStatus(
                    name: fd.name, exists: FileManager.default.fileExists(atPath: url.path),
                    intact: intact, totalSlices: expected, goodSlices: good))
            globalIndex += expected
        }

        try progress(1)
        let result = PAR2VerifyResult(
            sliceSize: recoverySet.sliceSize, files: statuses, totalInputSlices: blocks.count,
            missingSlices: missing, recoveryBlocksAvailable: recoverySet.recoverySlices.count)
        return (result, presence)
    }

    // MARK: - Repair

    public func repair() -> PAR2RepairResult {
        do { return try repair { _ in try Task.checkCancellation() } } catch {
            return .failed(reason: "Repair paused")
        }
    }

    /// Progress is also a cooperative cancellation boundary for verification and algebra workers.
    public func repair(progress: (Double) throws -> Void) rethrows -> PAR2RepairResult {
        try progress(0)
        guard recoverySet.isValid else { return .failed(reason: "No valid PAR2 recovery data.") }

        // Trim any file that is longer than its declared length before verifying: trailing bytes
        // beyond the true size make the full-file MD5 mismatch forever, so the file would be judged
        // damaged yet un-repairable (its slices are all present). fd.length is authoritative (from
        // an MD5-validated packet), so truncating to it is safe and is itself a repair.
        for fd in files where fd.length >= 0 {
            try progress(0)
            let url = fileURL(for: fd.name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
                size > fd.length, let handle = try? FileHandle(forWritingTo: url)
            else { continue }
            try? handle.truncate(atOffset: UInt64(fd.length))
            try? handle.synchronize()
            try? handle.close()
        }

        let (result, presence) = try verifyDetailed { try progress($0 * 0.2) }
        if result.isComplete { return .notNeeded }

        let missingIndices = presence.indices.filter { !presence[$0] }
        let m = missingIndices.count
        guard m <= recoverySet.recoverySlices.count else {
            return .insufficientRecoveryData(missing: m, available: recoverySet.recoverySlices.count)
        }

        guard m > 0, m <= 4096 else {
            return .failed(reason: "This recovery set cannot be repaired safely on this device.")
        }
        let memoryBudget = min(
            128 * 1024 * 1024, max(32 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 8)))
        let memoryNeeded = m * recoverySet.sliceSize + m * m * 2 + recoverySet.sliceSize * 3
        guard memoryNeeded <= memoryBudget else {
            return .failed(reason: "This repair needs more memory than is available safely on this device.")
        }

        let wordsPerBlock = recoverySet.sliceSize / 2
        let chosen = Array(recoverySet.recoverySlices.prefix(m))

        // RHS starts as the recovery data, then subtract present-block contributions. This is the
        // only place the recovery bytes are needed, and only `m` slices of them, so they are read
        // here instead of being held in memory since the set was parsed.
        var rhs: [[UInt16]] = []
        rhs.reserveCapacity(m)
        for (index, slice) in chosen.enumerated() {
            try progress(0.2 + Double(index) / Double(max(1, m)) * 0.05)
            guard let bytes = slice.read() else {
                return .failed(reason: "A recovery block is unreadable or damaged.")
            }
            rhs.append(wordsFromBytes(bytes, count: wordsPerBlock))
        }
        for gi in presence.indices where presence[gi] {
            try progress(0.25 + Double(gi) / Double(max(1, presence.count)) * 0.35)
            // Same pool discipline as verify: this walks every present block, so it reads the
            // whole payload as well.
            let read = try autoreleasepool { () throws -> Bool in
                guard let blockWords = readBlockWords(globalIndex: gi, wordsPerBlock: wordsPerBlock) else {
                    return false
                }
                let lb = baseLogs[gi]
                for r in 0..<m {
                    let coeff = GaloisField16.antilog((lb * chosen[r].exponent) % GaloisField16.limit)
                    try ReedSolomon.addScaled(&rhs[r], blockWords, coeff) {
                        try progress(0.25 + Double(gi) / Double(max(1, presence.count)) * 0.35)
                    }
                }
                return true
            }
            guard read else { return .failed(reason: "Couldn't read a good block while repairing.") }
        }

        // Coefficient matrix for the missing columns.
        var matrix = [UInt16](repeating: 0, count: m * m)
        for r in 0..<m {
            try progress(0.6 + Double(r) / Double(max(1, m)) * 0.05)
            let e = chosen[r].exponent
            for j in 0..<m {
                let lb = baseLogs[missingIndices[j]]
                matrix[r * m + j] = GaloisField16.antilog((lb * e) % GaloisField16.limit)
            }
        }

        guard
            try ReedSolomon.solve(
                matrix: &matrix, rhs: &rhs, m: m, progress: { try progress(0.65 + $0 * 0.25) })
        else {
            return .failed(reason: "The recovery blocks don't cover these files.")
        }

        // Write recovered blocks back to disk.
        for j in 0..<m {
            try progress(0.9 + Double(j) / Double(max(1, m)) * 0.05)
            if !writeBlock(globalIndex: missingIndices[j], words: rhs[j]) {
                return .failed(reason: "Couldn't write a rebuilt block.")
            }
        }

        // Safety net: a correct repair must make every file's MD5 match.
        let after = try verify { try progress(0.95 + $0 * 0.05) }
        return after.isComplete
            ? .repaired(blocks: m)
            : .failed(reason: "The rebuilt files still don't match their checksums.")
    }

    // MARK: - Block I/O

    private func readBlockWords(globalIndex: Int, wordsPerBlock: Int) -> [UInt16]? {
        let block = blocks[globalIndex]
        let fd = files[block.fileIndex]
        let url = fileURL(for: fd.name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(block.localSlice * recoverySet.sliceSize))
        let chunk = readFully(handle, count: recoverySet.sliceSize)
        return wordsFromBytes([UInt8](chunk), count: wordsPerBlock)
    }

    private func writeBlock(globalIndex: Int, words: [UInt16]) -> Bool {
        let block = blocks[globalIndex]
        let fd = files[block.fileIndex]
        let url = fileURL(for: fd.name)

        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        // Ensure the file is sized to its true length so the last (short) slice fits.
        if (try? handle.seekToEnd()) ?? 0 < UInt64(fd.length) {
            try? handle.truncate(atOffset: UInt64(fd.length))
        }
        let offset = block.localSlice * recoverySet.sliceSize
        let realBytes = min(recoverySet.sliceSize, max(0, fd.length - offset))
        guard realBytes > 0 else { return true }
        let bytes = bytesFromWords(words, byteCount: realBytes)
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: bytes)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func readFully(_ handle: FileHandle, count: Int) -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try? handle.read(upToCount: count - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    private func wordsFromBytes(_ bytes: [UInt8], count: Int) -> [UInt16] {
        var words = [UInt16](repeating: 0, count: count)
        for k in 0..<count {
            let i = k * 2
            let lo = i < bytes.count ? UInt16(bytes[i]) : 0
            let hi = i + 1 < bytes.count ? UInt16(bytes[i + 1]) : 0
            words[k] = lo | (hi << 8)
        }
        return words
    }

    private func bytesFromWords(_ words: [UInt16], byteCount: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(words.count * 2)
        for w in words {
            bytes.append(UInt8(w & 0xFF))
            bytes.append(UInt8((w >> 8) & 0xFF))
        }
        if bytes.count > byteCount { bytes.removeLast(bytes.count - byteCount) }
        return Data(bytes)
    }
}
