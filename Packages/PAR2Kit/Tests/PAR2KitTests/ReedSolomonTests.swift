import Testing
@testable import PAR2Kit

/// Exercises the exact PAR2 repair math (base constants, coefficient matrix, Gaussian solve)
/// end-to-end: encode recovery blocks, drop some input blocks, reconstruct, and check equality.
struct ReedSolomonTests {
    private let limit = GaloisField16.limit

    private func baseLogs(_ n: Int) -> [Int] {
        var logs: [Int] = []
        var lb = 0
        for _ in 0..<n {
            while GaloisField16.gcd(limit, lb) != 1 { lb += 1 }
            logs.append(lb)
            lb += 1
        }
        return logs
    }

    private func encodeRecovery(input: [[UInt16]], baseLogs: [Int], exponents: [Int], words: Int)
        -> [[UInt16]]
    {
        exponents.map { e in
            var acc = [UInt16](repeating: 0, count: words)
            for i in input.indices {
                let coeff = GaloisField16.antilog((baseLogs[i] * e) % limit)
                for k in 0..<words { acc[k] ^= GaloisField16.multiply(coeff, input[i][k]) }
            }
            return acc
        }
    }

    private func repair(
        input: [[UInt16]], missing: [Int], baseLogs: [Int],
        recovery: [[UInt16]], exponents: [Int], words: Int
    ) -> [[UInt16]]? {
        let m = missing.count
        var rhs = recovery
        for i in input.indices where !missing.contains(i) {
            for (ri, e) in exponents.enumerated() {
                let coeff = GaloisField16.antilog((baseLogs[i] * e) % limit)
                ReedSolomon.addScaled(&rhs[ri], input[i], coeff)
            }
        }
        var matrix = [UInt16](repeating: 0, count: m * m)
        for (ri, e) in exponents.enumerated() {
            for j in 0..<m {
                matrix[ri * m + j] = GaloisField16.antilog((baseLogs[missing[j]] * e) % limit)
            }
        }
        guard ReedSolomon.solve(matrix: &matrix, rhs: &rhs, m: m) else { return nil }
        return Array(rhs.prefix(m))
    }

    @Test func reconstructsMissingBlocks() {
        let n = 10, words = 32
        let logs = baseLogs(n)
        // Deterministic pseudo-random input blocks.
        var input: [[UInt16]] = []
        for i in 0..<n {
            input.append(
                (0..<words).map { k in UInt16(truncatingIfNeeded: (i * 2_654_435_761 + k * 40_503) >> 3) })
        }
        let exponents = Array(0..<5)
        let recovery = encodeRecovery(input: input, baseLogs: logs, exponents: exponents, words: words)

        // Drop as many blocks as we have recovery blocks.
        let missing = [0, 3, 6, 9, 4]  // 5 missing, 5 recovery blocks
        let solved = repair(
            input: input, missing: missing, baseLogs: logs,
            recovery: recovery, exponents: exponents, words: words)
        let recovered = try? #require(solved)
        for (j, gi) in missing.enumerated() {
            #expect(recovered?[j] == input[gi])
        }
    }

    @Test func reconstructsSingleMissingBlock() {
        let n = 4, words = 8
        let logs = baseLogs(n)
        let input: [[UInt16]] = (0..<n).map { i in
            (0..<words).map { UInt16(truncatingIfNeeded: i * 100 + $0) }
        }
        let exponents = [0]
        let recovery = encodeRecovery(input: input, baseLogs: logs, exponents: exponents, words: words)
        let solved = repair(
            input: input, missing: [2], baseLogs: logs,
            recovery: recovery, exponents: exponents, words: words)
        #expect(solved?[0] == input[2])
    }
}
