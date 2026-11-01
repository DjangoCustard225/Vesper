//
//  GaloisField16.swift
//  PAR2Kit
//
//  GF(2^16) arithmetic exactly as PAR2 / par2cmdline defines it: generator polynomial 0x1100B,
//  generator element 2 (log/antilog tables built by repeated `<<1` with reduction). Clean-room.
//

import Foundation

enum GaloisField16 {
    static let limit = 65535
    static let polynomial: UInt32 = 0x1_100B

    // log[v] = discrete log of v (base 2); antilog[k] = 2^k. Sizes 65536.
    private static let tables: (log: [UInt16], antilog: [UInt16]) = {
        var log = [UInt16](repeating: 0, count: 65536)
        var antilog = [UInt16](repeating: 0, count: 65536)
        var b: UInt32 = 1
        for l in 0..<65535 {
            log[Int(b)] = UInt16(l)
            antilog[l] = UInt16(b)
            b <<= 1
            if (b & 0x1_0000) != 0 { b ^= polynomial }
        }
        log[0] = UInt16(limit)  // par2: log[0] = Limit
        antilog[limit] = 0  // antilog[Limit] = 0
        return (log, antilog)
    }()

    @inline(__always) static func add(_ a: UInt16, _ b: UInt16) -> UInt16 { a ^ b }

    @inline(__always) static func multiply(_ a: UInt16, _ b: UInt16) -> UInt16 {
        if a == 0 || b == 0 { return 0 }
        var sum = Int(tables.log[Int(a)]) + Int(tables.log[Int(b)])
        if sum >= limit { sum -= limit }
        return tables.antilog[sum]
    }

    /// a raised to a non-negative power.
    static func pow(_ a: UInt16, _ exponent: Int) -> UInt16 {
        if exponent == 0 { return 1 }
        if a == 0 { return 0 }
        let logProduct = (Int(tables.log[Int(a)]) * exponent) % limit
        return tables.antilog[logProduct]
    }

    /// Multiplicative inverse (a != 0).
    static func inverse(_ a: UInt16) -> UInt16 {
        precondition(a != 0, "no inverse for 0")
        let l = (limit - Int(tables.log[Int(a)])) % limit
        return tables.antilog[l]
    }

    /// 2^k — the antilog, used to derive input-block base constants.
    static func antilog(_ k: Int) -> UInt16 { tables.antilog[k % limit] }

    /// Whether `k` is a valid logbase for an input-block constant (par2: gcd(65535, k) == 1).
    static func isValidLogBase(_ k: Int) -> Bool { gcd(limit, k) == 1 }

    static func gcd(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
