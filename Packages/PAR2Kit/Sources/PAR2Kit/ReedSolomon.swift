//
//  ReedSolomon.swift
//  PAR2Kit
//
//  Solves the PAR2 Reed-Solomon system to reconstruct missing input blocks. Each block is a
//  vector of GF(2^16) words; row operations apply a scalar GF multiply across a whole block.
//
//  Relationship (per recovery block with exponent e):  R_e = Σ_i  base_i^e · D_i
//  To recover the M missing blocks we pick M recovery blocks and solve  M · X = Y, where
//  M[r][j] = base_{missing_j}^{e_r} and Y_r = R_{e_r} − Σ_{present p} base_p^{e_r} · D_p.
//

import Foundation

enum ReedSolomon {
    /// Solve `matrix · X = rhs` in place (Gaussian elimination, reduced row echelon).
    /// `matrix` is m×m row-major; `rhs` is m word-blocks. On success `rhs[i]` holds X[i].
    /// Returns false if the matrix is singular (shouldn't happen for a valid PAR2 set).
    static func solve(matrix: inout [UInt16], rhs: inout [[UInt16]], m: Int) -> Bool {
        solve(matrix: &matrix, rhs: &rhs, m: m, progress: { _ in })
    }

    static func solve(
        matrix: inout [UInt16], rhs: inout [[UInt16]], m: Int,
        progress: (Double) throws -> Void
    ) rethrows -> Bool {
        try progress(0)
        for col in 0..<m {
            try progress(Double(col) / Double(max(1, m)))
            // Find a non-zero pivot in this column.
            var pivot = -1
            for r in col..<m where matrix[r * m + col] != 0 { pivot = r; break }
            guard pivot >= 0 else { return false }

            if pivot != col {
                for c in 0..<m { matrix.swapAt(pivot * m + c, col * m + c) }
                rhs.swapAt(pivot, col)
            }

            // Normalize the pivot row so the pivot becomes 1.
            let inv = GaloisField16.inverse(matrix[col * m + col])
            if inv != 1 {
                for c in 0..<m { matrix[col * m + c] = GaloisField16.multiply(matrix[col * m + c], inv) }
                try scale(&rhs[col], by: inv) { try progress(Double(col) / Double(max(1, m))) }
            }

            // Eliminate this column from every other row.
            for r in 0..<m where r != col {
                let factor = matrix[r * m + col]
                if factor == 0 { continue }
                for c in 0..<m {
                    matrix[r * m + c] ^= GaloisField16.multiply(factor, matrix[col * m + c])
                }
                try addScaled(&rhs[r], rhs[col], factor) { try progress(Double(col) / Double(max(1, m))) }
            }
        }
        try progress(1)
        return true
    }

    /// block *= scalar (word-wise GF multiply).
    static func scale(_ block: inout [UInt16], by scalar: UInt16) {
        scale(&block, by: scalar, checkpoint: {})
    }
    static func scale(
        _ block: inout [UInt16], by scalar: UInt16,
        checkpoint: () throws -> Void
    ) rethrows {
        for k in 0..<block.count {
            if k % 8192 == 0 { try checkpoint() }
            block[k] = GaloisField16.multiply(block[k], scalar)
        }
    }

    /// dst ^= scalar · src  (word-wise).
    static func addScaled(_ dst: inout [UInt16], _ src: [UInt16], _ scalar: UInt16) {
        addScaled(&dst, src, scalar, checkpoint: {})
    }
    static func addScaled(
        _ dst: inout [UInt16], _ src: [UInt16], _ scalar: UInt16,
        checkpoint: () throws -> Void
    ) rethrows {
        let count = min(dst.count, src.count)
        for k in 0..<count {
            if k % 8192 == 0 { try checkpoint() }
            dst[k] ^= GaloisField16.multiply(scalar, src[k])
        }
    }
}
