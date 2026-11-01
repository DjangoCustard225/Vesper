//
//  CRC32.swift
//  DownloadEngine
//
//  Standard CRC-32 (IEEE 802.3, polynomial 0xEDB88320) — the checksum yEnc uses for its
//  `pcrc32` / `crc32` integrity fields. Table-based, incremental, pure Swift.
//

import Foundation

public struct CRC32: Sendable {
    // Precomputed lookup table (256 entries), built once.
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    /// Feed more bytes into the running checksum.
    public mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        var c = state
        let table = Self.table
        for b in bytes {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        state = c
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            var c = state
            let table = Self.table
            for b in raw {
                c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
            }
            state = c
        }
    }

    /// The current checksum value.
    public var checksum: UInt32 { state ^ 0xFFFF_FFFF }

    /// One-shot convenience.
    public static func checksum(of data: Data) -> UInt32 {
        var c = CRC32()
        c.update(data)
        return c.checksum
    }
}
