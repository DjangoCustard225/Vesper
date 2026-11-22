import Foundation
#if canImport(Compression)
import Compression
#endif

/// Reads only a bounded subtitle entry into memory; archive paths are never written to disk.
enum SubDLArchive {
    private struct Entry {
        let name: String
        let method: Int
        let compressed: Int
        let expanded: Int
        let localOffset: Int
        let checksum: UInt32
    }

    static func subtitle(from data: Data, season: Int?, episode: Int?) throws -> Data {
        let bytes = data
        func word(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - 2 else { throw SubDLError.archive }
            return Int(bytes[bytes.startIndex + offset]) | Int(bytes[bytes.startIndex + offset + 1]) << 8
        }
        func dword(_ offset: Int) throws -> Int {
            try word(offset) | word(offset + 2) << 16
        }
        guard bytes.count >= 22 else { throw SubDLError.archive }
        let start = max(0, bytes.count - 65_557)
        guard
            let end = stride(from: bytes.count - 22, through: start, by: -1).first(where: {
                (try? dword($0)) == 0x06054b50 && (try? word($0 + 20)) == bytes.count - $0 - 22
            })
        else { throw SubDLError.archive }
        guard try word(end + 4) == 0, try word(end + 6) == 0,
            try word(end + 8) == word(end + 10), try word(end + 10) <= 1_000
        else { throw SubDLError.archive }
        let count = try word(end + 10), size = try dword(end + 12), offset = try dword(end + 16)
        guard offset <= end, size <= end - offset else { throw SubDLError.archive }
        var cursor = offset
        var entries: [Entry] = []
        for _ in 0..<count {
            guard cursor <= end - 46, try dword(cursor) == 0x02014b50 else { throw SubDLError.archive }
            let flags = try word(cursor + 8), method = try word(cursor + 10)
            let compressed = try dword(cursor + 20), expanded = try dword(cursor + 24)
            let nameLength = try word(cursor + 28), extraLength = try word(cursor + 30),
                commentLength = try word(cursor + 32)
            let total = 46 + nameLength + extraLength + commentLength
            guard total <= end - cursor else { throw SubDLError.archive }
            let nameData = bytes.subdata(
                in: (bytes.startIndex + cursor + 46)..<(bytes.startIndex + cursor + 46 + nameLength))
            let name =
                String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .windowsCP1252)
                ?? ""
            let ext = (name as NSString).pathExtension.lowercased()
            if ["srt", "vtt", "ass", "ssa"].contains(ext), !name.hasPrefix("__MACOSX/"),
                !(name as NSString).lastPathComponent.hasPrefix("._"), flags & 1 == 0,
                [0, 8].contains(method), expanded > 0, expanded <= 8 * 1024 * 1024,
                compressed > 0, compressed <= 8 * 1024 * 1024
            {
                entries.append(
                    Entry(
                        name: name, method: method, compressed: compressed, expanded: expanded,
                        localOffset: try dword(cursor + 42), checksum: UInt32(try dword(cursor + 16))))
            }
            cursor += total
        }
        guard cursor == offset + size else { throw SubDLError.archive }
        let selected: Entry
        if entries.count == 1 {
            selected = entries[0]
        } else if let season, let episode {
            let pattern =
                "(?i)(?:s0*\(season)[ ._-]*e0*\(episode)(?![0-9])|(?<![0-9])0*\(season)x0*\(episode)(?![0-9]))"
            let matches = entries.filter { $0.name.range(of: pattern, options: .regularExpression) != nil }
            guard matches.count == 1 else { throw SubDLError.archive }
            selected = matches[0]
        } else {
            throw SubDLError.archive
        }
        let local = selected.localOffset
        guard local <= offset - 30, try dword(local) == 0x04034b50,
            try word(local + 8) == selected.method, try word(local + 6) & 1 == 0
        else { throw SubDLError.archive }
        let payload = try local + 30 + word(local + 26) + word(local + 28)
        guard payload <= offset, selected.compressed <= offset - payload else {
            throw SubDLError.archive
        }
        let compressed = bytes.subdata(
            in: (bytes.startIndex + payload)..<(bytes.startIndex + payload + selected.compressed))
        if selected.method == 0 {
            guard compressed.count == selected.expanded, checksum(compressed) == selected.checksum else {
                throw SubDLError.archive
            }
            return compressed
        }
        #if canImport(Compression)
        var output = Data(count: selected.expanded)
        let decodedCount = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, selected.expanded,
                    source.bindMemory(to: UInt8.self).baseAddress!, selected.compressed,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard decodedCount == selected.expanded, checksum(output) == selected.checksum else {
            throw SubDLError.archive
        }
        return output
        #else
        throw SubDLError.archive
        #endif
    }

    private static let checksumTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }

    private static func checksum(_ data: Data) -> UInt32 {
        ~data.reduce(UInt32.max) { crc, byte in
            (crc >> 8) ^ checksumTable[Int((crc ^ UInt32(byte)) & 0xff)]
        }
    }
}
