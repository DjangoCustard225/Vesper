import Foundation

struct RARPart: Sendable {
    let name: String
    let offset: Int64
    let length: Int64
    let unpacked: Int64?
    let before: Bool
    let after: Bool
    let encrypted: Bool
    let compressed: Bool
    var cipher: RARCipher? = nil
}
struct RARVolume: Sendable { let parts: [RARPart]; let next: Bool }

struct BinaryCursor {
    let bytes: [UInt8]
    var index: Int
    init(_ data: Data, index: Int = 0) { bytes = Array(data); self.index = index }
    mutating func uint(_ count: Int) throws -> UInt64 {
        guard count >= 0, count <= 8, index >= 0, index <= bytes.count - count else {
            throw UsenetError.corrupt
        }
        var value: UInt64 = 0
        for shift in 0..<count { value |= UInt64(bytes[index + shift]) << (shift * 8) }; index += count;
        return value
    }
    mutating func vint() throws -> Int64 {
        var value: UInt64 = 0
        for part in 0..<10 {
            let byte = try uint(1)
            guard part < 9 || byte <= 1 else { throw UsenetError.corrupt }
            value |= (byte & 127) << (part * 7)
            if byte & 128 == 0 {
                guard value <= UInt64(Int64.max) else { throw UsenetError.corrupt }; return Int64(value)
            }
        }
        throw UsenetError.corrupt
    }
    mutating func data(_ count: Int) throws -> Data {
        guard count >= 0, index >= 0, index <= bytes.count - count else { throw UsenetError.corrupt }
        defer { index += count }; return Data(bytes[index..<(index + count)])
    }
}

private struct RAR5Encryption {
    let salt: Data
    let logRounds: Int
    let iv: Data
    let check: Data?
    let checkHash: Data?
    func cipher(_ keys: RARKeyStore, iv override: Data? = nil, headerChecked: Bool = false) async throws
        -> RARCipher
    {
        try await keys.rar5(
            salt: salt, logRounds: logRounds, iv: override ?? iv, check: check, checkHash: checkHash,
            headerChecked: headerChecked)
    }
}

enum StoredRAR {
    static func scan(_ resource: any ByteResource, keys: RARKeyStore? = nil) async throws -> RARVolume {
        let size = try await resource.size()
        guard size >= 8 else { throw UsenetError.unsupported }
        let magic = try await resource.read(offset: 0, count: 8, priority: .playback)
        if magic.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0]) {
            return try await scan4(resource, length: size, keys: keys)
        }
        if magic == Data([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 1, 0]) {
            return try await scan5(resource, length: size, keys: keys)
        }
        throw UsenetError.unsupported
    }
    private static func bytes(_ resource: any ByteResource, offset: Int64, count: Int) async throws -> Data {
        let data = try await resource.read(offset: offset, count: count, priority: .playback)
        guard data.count == count else { throw UsenetError.corrupt }; return data
    }
    private static func aligned(_ count: Int) -> Int { (count + 15) & ~15 }
    private static func scan4(_ resource: any ByteResource, length: Int64, keys: RARKeyStore?) async throws
        -> RARVolume
    {
        var offset: Int64 = 7, result: [RARPart] = [], encryptedHeaders = false
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            guard offset <= length - 7 else { throw UsenetError.corrupt }
            let header: Data, payload: Int64
            if encryptedHeaders {
                guard let keys else { throw UsenetError.encrypted }
                guard offset <= length - 24 else { throw UsenetError.corrupt }
                let salt = try await bytes(resource, offset: offset, count: 8)
                let cipher = try await keys.rar3(salt: salt)
                let first = try cipher.decrypt(try await bytes(resource, offset: offset + 8, count: 16))
                var base = BinaryCursor(first, index: 5); let size = Int(try base.uint(2))
                guard size >= 7, offset + 8 + Int64(aligned(size)) <= length else {
                    throw UsenetError.badPassword
                }
                header = Data(
                    try cipher.decrypt(try await bytes(resource, offset: offset + 8, count: aligned(size)))
                        .prefix(size))
                payload = offset + 8 + Int64(aligned(size))
            } else {
                var base = BinaryCursor(try await bytes(resource, offset: offset, count: 7), index: 5)
                let size = Int(try base.uint(2))
                guard size >= 7, offset + Int64(size) <= length else { throw UsenetError.corrupt }
                header = try await bytes(resource, offset: offset, count: size);
                payload = offset + Int64(size)
            }
            var base = BinaryCursor(header)
            let checksum = try base.uint(2), type = try base.uint(1), flags = try base.uint(2);
            _ = try base.uint(2)
            guard UInt64(CRC32.checksum(of: header.dropFirst(2)) & 0xffff) == checksum else {
                throw encryptedHeaders ? UsenetError.badPassword : UsenetError.corrupt
            }
            var cursor = BinaryCursor(header, index: 7)
            var dataSize = flags & 0x8000 != 0 ? Int64(try cursor.uint(4)) : 0
            if type == 0x73, flags & 0x80 != 0 { encryptedHeaders = true }
            if type == 0x74 {
                guard flags & 0x8000 != 0, header.count >= 32 else { throw UsenetError.corrupt }
                var unpacked = try cursor.uint(4)
                _ = try cursor.uint(1); _ = try cursor.uint(4); _ = try cursor.uint(4)
                let version = try cursor.uint(1), method = try cursor.uint(1),
                    nameLength = Int(try cursor.uint(2))
                ; _ = try cursor.uint(4)
                if flags & 0x100 != 0 {
                    let highPacked = try cursor.uint(4), highUnpacked = try cursor.uint(4)
                    guard highPacked <= UInt64(Int64.max) >> 32 else { throw UsenetError.corrupt }
                    dataSize |= Int64(highPacked << 32); unpacked |= highUnpacked << 32
                }
                let raw = try cursor.data(nameLength), ansi = raw.prefix { $0 != 0 }
                guard
                    let name = String(data: ansi, encoding: .utf8)
                        ?? String(data: ansi, encoding: .isoLatin1), !name.isEmpty
                else { throw UsenetError.corrupt }
                var cipher: RARCipher?
                if flags & 4 != 0, let keys, method == 0x30, UsenetVideo.isVideo(name) {
                    guard version >= 29 else { throw UsenetError.unsupported }
                    let salt = flags & 0x400 != 0 ? try cursor.data(8) : Data()
                    cipher = try await keys.rar3(salt: salt, checked: encryptedHeaders)
                }
                result.append(
                    RARPart(
                        name: name, offset: payload, length: dataSize,
                        unpacked: unpacked == UInt64.max || unpacked == UInt32.max
                            ? nil : Int64(exactly: unpacked), before: flags & 1 != 0, after: flags & 2 != 0,
                        encrypted: flags & 4 != 0, compressed: method != 0x30, cipher: cipher))
            }
            offset = try checkedAdd(payload, dataSize)
            guard offset <= length else { throw UsenetError.corrupt }
            if type == 0x7b { return RARVolume(parts: result, next: flags & 1 != 0) }
            if offset == length { return RARVolume(parts: result, next: result.last?.after == true) }
        }
        throw UsenetError.unsupported
    }
    private static func encryption5(_ cursor: inout BinaryCursor, withIV: Bool) throws -> RAR5Encryption {
        guard try cursor.vint() == 0 else { throw UsenetError.unsupported }
        let flags = try cursor.vint(), rounds = Int(try cursor.uint(1))
        guard rounds <= 20 else { throw UsenetError.unsupported }
        let salt = try cursor.data(16), iv = withIV ? try cursor.data(16) : Data(repeating: 0, count: 16)
        let check = flags & 1 != 0 ? try cursor.data(8) : nil
        let hash = flags & 1 != 0 ? try cursor.data(4) : nil
        return RAR5Encryption(salt: salt, logRounds: rounds, iv: iv, check: check, checkHash: hash)
    }
    private static func scan5(_ resource: any ByteResource, length: Int64, keys: RARKeyStore?) async throws
        -> RARVolume
    {
        var offset: Int64 = 8, result: [RARPart] = [], headers: RAR5Encryption?
        for _ in 0..<100_000 {
            try Task.checkCancellation()
            guard offset <= length - 7 else { throw UsenetError.corrupt }
            let header: Data, payload: Int64, headerStart: Int
            if let encryption = headers {
                guard let keys, offset <= length - 32 else {
                    throw keys == nil ? UsenetError.encrypted : UsenetError.corrupt
                }
                let iv = try await bytes(resource, offset: offset, count: 16)
                let cipher = try await encryption.cipher(keys, iv: iv)
                let first = try cipher.decrypt(try await bytes(resource, offset: offset + 16, count: 16))
                var head = BinaryCursor(first, index: 4)
                let count: Int64
                do { count = try head.vint() } catch {
                    throw cipher.passwordChecked ? UsenetError.corrupt : UsenetError.badPassword
                }
                headerStart = head.index
                guard count > 0, count <= 1024 * 1024,
                    offset + 16 + Int64(aligned(headerStart + Int(count))) <= length
                else { throw cipher.passwordChecked ? UsenetError.corrupt : UsenetError.badPassword }
                let full = headerStart + Int(count)
                header = Data(
                    try cipher.decrypt(try await bytes(resource, offset: offset + 16, count: aligned(full)))
                        .prefix(full))
                payload = offset + 16 + Int64(aligned(full))
            } else {
                let first = try await bytes(resource, offset: offset, count: Int(min(16, length - offset)))
                var head = BinaryCursor(first, index: 4)
                let count = try head.vint(); headerStart = head.index
                guard count > 0, count <= 1024 * 1024, offset + Int64(headerStart) + count <= length else {
                    throw UsenetError.corrupt
                }
                header = try await bytes(resource, offset: offset, count: headerStart + Int(count));
                payload = offset + Int64(header.count)
            }
            var checksumCursor = BinaryCursor(header)
            guard UInt64(CRC32.checksum(of: header.dropFirst(4))) == (try checksumCursor.uint(4)) else {
                throw headers == nil || headers?.check != nil ? UsenetError.corrupt : UsenetError.badPassword
            }
            var cursor = BinaryCursor(header, index: headerStart)
            let type = try cursor.vint(), flags = try cursor.vint()
            let extra = flags & 1 != 0 ? try cursor.vint() : 0,
                dataSize = flags & 2 != 0 ? try cursor.vint() : 0
            guard extra <= header.count - cursor.index else { throw UsenetError.corrupt }
            if type == 4 {
                guard headers == nil else { throw UsenetError.corrupt }
                headers = try encryption5(&cursor, withIV: false)
                guard let keys else { throw UsenetError.encrypted }
                _ = try await headers!.cipher(keys)
            }
            if type == 2 {
                let fileFlags = try cursor.vint(), unpacked = try cursor.vint(); _ = try cursor.vint()
                if fileFlags & 2 != 0 { _ = try cursor.uint(4) }
                if fileFlags & 4 != 0 { _ = try cursor.uint(4) }
                let compression = try cursor.vint(); _ = try cursor.vint()
                let nameLength = try cursor.vint()
                guard nameLength > 0, nameLength <= 4096,
                    cursor.index + Int(nameLength) <= header.count - Int(extra)
                else { throw UsenetError.corrupt }
                guard let name = String(data: try cursor.data(Int(nameLength)), encoding: .utf8) else {
                    throw UsenetError.corrupt
                }
                var encrypted = false, redirected = false, cipher: RARCipher?
                if extra > 0 {
                    var extras = BinaryCursor(header, index: header.count - Int(extra))
                    while extras.index < header.count {
                        let count = try extras.vint()
                        guard count > 0, count <= header.count - extras.index else {
                            throw UsenetError.corrupt
                        }
                        var record = BinaryCursor(try extras.data(Int(count)))
                        let kind = try record.vint()
                        if kind == 1 {
                            encrypted = true
                            if let keys, compression & 0x380 == 0, UsenetVideo.isVideo(name) {
                                cipher = try await encryption5(&record, withIV: true).cipher(
                                    keys, headerChecked: headers != nil)
                            }
                        }
                        if kind == 5 { redirected = true }
                    }
                }
                if fileFlags & 1 == 0 {
                    if redirected { throw UsenetError.unsupported }
                    result.append(
                        RARPart(
                            name: name, offset: payload, length: dataSize,
                            unpacked: fileFlags & 8 != 0 ? nil : unpacked, before: flags & 8 != 0,
                            after: flags & 16 != 0, encrypted: encrypted,
                            compressed: compression & 0x380 != 0, cipher: cipher))
                }
            }
            let next = try checkedAdd(payload, dataSize)
            guard next <= length else { throw UsenetError.corrupt }
            if type == 5 { return RARVolume(parts: result, next: try cursor.vint() & 1 != 0) }
            offset = next
            if offset == length { return RARVolume(parts: result, next: result.last?.after == true) }
        }
        throw UsenetError.unsupported
    }
    static func videos(_ volumes: [(Int, RARVolume)], startingAt firstID: Int) throws -> [UsenetVideo] {
        var videos: [UsenetVideo] = [], name: String?, extents: [VideoExtent] = [], expected: Int64?,
            cipher: RARCipher?
        for (position, pair) in volumes.enumerated() {
            if position == volumes.count - 1, pair.1.next { throw UsenetError.missingArticle }
            for part in pair.1.parts {
                guard part.length >= 0 else { throw UsenetError.corrupt }
                if part.before {
                    guard name == part.name, !extents.isEmpty else { throw UsenetError.missingArticle }
                } else {
                    guard name == nil else { throw UsenetError.missingArticle }
                    name = part.name; extents = []; expected = part.unpacked; cipher = part.cipher
                }
                if UsenetVideo.isVideo(part.name) {
                    if part.compressed { throw UsenetError.compressed }
                    if part.encrypted && part.cipher == nil { throw UsenetError.encrypted }
                    guard part.cipher?.key == cipher?.key, part.cipher?.iv == cipher?.iv else {
                        throw UsenetError.corrupt
                    }
                }
                extents.append(VideoExtent(fileID: pair.0, offset: part.offset, length: part.length))
                let total = try extents.reduce(Int64(0)) { try checkedAdd($0, $1.length) }
                if !part.after {
                    if UsenetVideo.isVideo(part.name) {
                        let plain = part.unpacked ?? expected
                        if cipher != nil {
                            guard let plain, plain > 0, plain <= total, total - plain < 16, total % 16 == 0
                            else { throw UsenetError.corrupt }
                        } else if let plain, plain != total {
                            throw UsenetError.corrupt
                        }
                        videos.append(
                            UsenetVideo(
                                id: firstID + videos.count, name: (part.name as NSString).lastPathComponent,
                                extents: extents, cipher: cipher, plainLength: plain))
                    }
                    name = nil; extents = []; expected = nil; cipher = nil
                }
            }
        }
        guard name == nil else { throw UsenetError.missingArticle }; return videos
    }
}
