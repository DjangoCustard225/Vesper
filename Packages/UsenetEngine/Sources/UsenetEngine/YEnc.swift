//
//  YEnc.swift
//  DownloadEngine
//
//  yEnc decoder (https://www.yenc.org). Decodes the body of one Usenet article (a single
//  NZB segment) into raw bytes, parses the =ybegin/=ypart/=yend headers, and verifies the
//  per-part CRC-32. Operates on the already dot-unstuffed, CRLF-stripped content lines.
//

import Foundation

public struct YEncHeader: Equatable, Sendable {
    public var name: String?
    public var lineLength: Int?
    /// `size=` from =ybegin (the whole-file size for multipart, or the file size for single).
    public var size: Int?
    /// `part=` from =ybegin (1-based part number); nil for single-part.
    public var part: Int?
    public var total: Int?
    /// `begin=`/`end=` from =ypart — 1-based, inclusive byte offsets into the assembled file.
    public var partBegin: Int?
    public var partEnd: Int?

    public var isMultipart: Bool { part != nil || partBegin != nil }
}

public struct YEncDecodedSegment: Sendable {
    public var data: Data
    public var header: YEncHeader
    /// `size=` from =yend (the size of THIS part's decoded data).
    public var declaredPartSize: Int?
    /// The CRC the article claims for this part: `pcrc32` if present, else whole-file `crc32`.
    public var declaredCRC: UInt32?
    public var computedCRC: UInt32
    /// nil when the article declared no CRC for this part.
    public var crcMatches: Bool?
    /// 0-based byte offset where this segment's decoded bytes belong in the assembled file.
    public var fileOffset: Int
}

public enum YEncError: Error, Equatable, Sendable {
    case missingBeginHeader
    case emptyBody
    case invalidStructure
}

public enum YEncDecoder {
    private static let escape: UInt8 = 0x3D  // '='
    private static let yByte: UInt8 = 0x79  // 'y'

    /// Decode one article body (its content lines) into a positioned, CRC-checked segment.
    public static func decode(bodyLines: [Data]) throws -> YEncDecodedSegment {
        var header = YEncHeader()
        var sawBegin = false
        var sawEnd = false
        var declaredPartSize: Int?
        var pcrc: UInt32?
        var fileCRC: UInt32?

        // Decode into a plain byte array (per-byte Data.append pays a Foundation call on every
        // downloaded byte); wrap it in Data once at the end.
        var out = [UInt8]()
        var capacity = 0
        for line in bodyLines {
            guard line.count <= 8 * 1024 * 1024 - capacity else { throw YEncError.invalidStructure }
            capacity += line.count
        }
        out.reserveCapacity(capacity)
        var escapePending = false

        for line in bodyLines {
            if isKeyword(line, "=ybegin") {
                guard !sawBegin else { throw YEncError.invalidStructure }
                parseBegin(line, into: &header)
                sawBegin = true
                continue
            }
            if isKeyword(line, "=ypart") {
                guard sawBegin, header.partBegin == nil else { throw YEncError.invalidStructure }
                parsePart(line, into: &header)
                continue
            }
            if isKeyword(line, "=yend") {
                guard sawBegin else { throw YEncError.invalidStructure }; sawEnd = true
                let attrs = attributes(of: line, keyword: "=yend")
                declaredPartSize = attrs["size"].flatMap { Int($0) }
                pcrc = attrs["pcrc32"].flatMap { UInt32($0, radix: 16) }
                fileCRC = attrs["crc32"].flatMap { UInt32($0, radix: 16) }
                guard attrs["pcrc32"] == nil || pcrc != nil, attrs["crc32"] == nil || fileCRC != nil else {
                    throw YEncError.invalidStructure
                }
                break
            }
            guard sawBegin else { continue }
            // Data line — decode bytes.
            line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for b in raw {
                    if escapePending {
                        out.append(b &- 106)
                        escapePending = false
                    } else if b == escape {
                        escapePending = true
                    } else {
                        out.append(b &- 42)
                    }
                }
            }
        }

        guard sawBegin else { throw YEncError.missingBeginHeader }
        guard sawEnd, !escapePending, !out.isEmpty, declaredPartSize == out.count,
            let fullSize = header.size, fullSize > 0
        else { throw YEncError.invalidStructure }
        if header.isMultipart {
            guard let begin = header.partBegin, let end = header.partEnd, begin > 0, end >= begin,
                end <= fullSize, end - begin + 1 == out.count,
                header.part.map({ $0 > 0 }) ?? true
            else { throw YEncError.invalidStructure }
        } else {
            guard out.count == fullSize else { throw YEncError.invalidStructure }
        }

        let outData = Data(out)
        var crc = CRC32()
        crc.update(outData)
        let computed = crc.checksum
        // The whole-file `crc32` only describes THIS part when the article is single-part. For a
        // multipart segment we can only verify against the part-level `pcrc32`; if the poster
        // omitted it, accept the part (checking it against the whole-file CRC would falsely fail
        // every segment and mark it missing).
        let declared = pcrc ?? (header.isMultipart ? nil : fileCRC)
        let matches = declared.map { $0 == computed }
        guard matches != false else { throw YEncError.invalidStructure }

        let fileOffset = (header.partBegin.map { $0 - 1 }) ?? 0

        return YEncDecodedSegment(
            data: outData,
            header: header,
            declaredPartSize: declaredPartSize,
            declaredCRC: declared,
            computedCRC: computed,
            crcMatches: matches,
            fileOffset: max(0, fileOffset)
        )
    }

    // MARK: - Header parsing

    private static func parseBegin(_ line: Data, into header: inout YEncHeader) {
        let attrs = attributes(of: line, keyword: "=ybegin")
        header.lineLength = attrs["line"].flatMap { Int($0) }
        header.size = attrs["size"].flatMap { Int($0) }
        header.part = attrs["part"].flatMap { Int($0) }
        header.total = attrs["total"].flatMap { Int($0) }
        if let name = attrs["name"], !name.isEmpty { header.name = name }
    }

    private static func parsePart(_ line: Data, into header: inout YEncHeader) {
        let attrs = attributes(of: line, keyword: "=ypart")
        header.partBegin = attrs["begin"].flatMap { Int($0) }
        header.partEnd = attrs["end"].flatMap { Int($0) }
    }

    /// True if `line` begins with the given keyword (ASCII compare on the raw bytes).
    private static func isKeyword(_ line: Data, _ keyword: String) -> Bool {
        let kw = Array(keyword.utf8)
        guard line.count > kw.count, line[line.index(line.startIndex, offsetBy: kw.count)] == 32 else {
            return false
        }
        for (i, byte) in kw.enumerated() where line[line.index(line.startIndex, offsetBy: i)] != byte {
            return false
        }
        return true
    }

    /// Parse `key=value` attributes from a yEnc header line. `name=` (when present) is always
    /// last and captures the remainder of the line, so it is extracted first.
    private static func attributes(of line: Data, keyword: String) -> [String: String] {
        // Latin-1 never fails and round-trips bytes 1:1 (filenames may be non-UTF8).
        guard var s = String(data: line, encoding: .isoLatin1) else { return [:] }
        if s.hasPrefix(keyword) { s.removeFirst(keyword.count) }

        var result: [String: String] = [:]

        if let r = s.range(of: " name=") {
            let name = String(s[r.upperBound...])
            result["name"] = name
            s = String(s[..<r.lowerBound])
        }

        for token in s.split(separator: " ") where token.contains("=") {
            let parts = token.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
            }
        }
        return result
    }
}
