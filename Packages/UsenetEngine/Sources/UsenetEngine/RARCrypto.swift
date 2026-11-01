import Foundation
import CUsenetCrypto

struct RARCipher: Sendable, Equatable {
    let key: Data
    let iv: Data
    let passwordChecked: Bool
    func decrypt(_ data: Data, iv override: Data? = nil) throws -> Data {
        let iv = override ?? self.iv
        guard iv.count == 16, !data.isEmpty, data.count % 16 == 0 else { throw UsenetError.corrupt }
        var result = Data(count: data.count)
        let success = result.withUnsafeMutableBytes { output in
            key.withUnsafeBytes { key in
                iv.withUnsafeBytes { iv in
                    data.withUnsafeBytes { input in
                        vesper_aes_decrypt(
                            key.bindMemory(to: UInt8.self).baseAddress!, key.count,
                            iv.bindMemory(to: UInt8.self).baseAddress!,
                            input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                            output.bindMemory(to: UInt8.self).baseAddress!)
                    }
                }
            }
        }
        guard success == 1 else { throw UsenetError.corrupt }; return result
    }
}

/// Derived material and the password live only for the current streaming session.
actor RARKeyStore {
    private let password: String
    private let legacyUnicode: Bool
    private var keys: [Data: (Data, Data)] = [:]
    init(password: String, legacyUnicode: Bool = false) {
        self.password = password; self.legacyUnicode = legacyUnicode
    }
    func rar3(salt: Data, checked: Bool = false) throws -> RARCipher {
        try Task.checkCancellation()
        guard !password.isEmpty, password.utf16.count <= 256, !password.contains("\0"),
            salt.isEmpty || salt.count == 8
        else {
            throw UsenetError.unsupported
        }
        let cacheID = Data([3]) + salt
        if let (key, iv) = keys[cacheID] { return RARCipher(key: key, iv: iv, passwordChecked: checked) }
        var raw = Data()
        // Historical Unix RAR3 releases stored the low 16 bits of each wide character.
        let units =
            legacyUnicode
            ? password.unicodeScalars.map { UInt16(truncatingIfNeeded: $0.value) } : Array(password.utf16)
        for value in units {
            raw.append(UInt8(truncatingIfNeeded: value)); raw.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        var key = Data(count: 16), iv = Data(count: 16)
        let success = key.withUnsafeMutableBytes { key in
            iv.withUnsafeMutableBytes { iv in
                raw.withUnsafeBytes { raw in
                    salt.withUnsafeBytes { salt in
                        vesper_rar3_key(
                            raw.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                            salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                            key.bindMemory(to: UInt8.self).baseAddress!,
                            iv.bindMemory(to: UInt8.self).baseAddress!)
                    }
                }
            }
        }
        guard success == 1 else { throw UsenetError.unsupported }
        try Task.checkCancellation(); remember(cacheID, key: key, value: iv)
        return RARCipher(key: key, iv: iv, passwordChecked: checked)
    }
    func rar5(
        salt: Data, logRounds: Int, iv: Data, check: Data? = nil, checkHash: Data? = nil,
        headerChecked: Bool = false
    ) throws -> RARCipher {
        try Task.checkCancellation()
        guard !password.isEmpty, salt.count == 16, iv.count == 16, (0...20).contains(logRounds),
            password.utf8.count <= 1024,
            !password.contains("\0")
        else { throw UsenetError.unsupported }
        let cacheID = Data([5, UInt8(logRounds)]) + salt
        let key: Data, verification: Data
        if let existing = keys[cacheID] {
            key = existing.0; verification = existing.1
        } else {
            let raw = Data(password.utf8)
            var derived = Data(count: 32), verify = Data(count: 8)
            let success = derived.withUnsafeMutableBytes { key in
                verify.withUnsafeMutableBytes { verification in
                    raw.withUnsafeBytes { raw in
                        salt.withUnsafeBytes { salt in
                            vesper_rar5_key(
                                raw.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                salt.bindMemory(to: UInt8.self).baseAddress!, UInt32(logRounds),
                                key.bindMemory(to: UInt8.self).baseAddress!,
                                verification.bindMemory(to: UInt8.self).baseAddress!)
                        }
                    }
                }
            }
            guard success == 1 else { throw UsenetError.unsupported }; try Task.checkCancellation()
            remember(cacheID, key: derived, value: verify); key = derived; verification = verify
        }
        if let check {
            guard check.count == 8, let checkHash, checkHash.count == 4,
                try Self.hash(check).prefix(4) == checkHash
            else { throw UsenetError.corrupt }
            guard Self.equal(check, verification) else { throw UsenetError.badPassword }
        }
        return RARCipher(key: key, iv: iv, passwordChecked: headerChecked || check != nil)
    }
    func clear() { keys.removeAll() }
    private func remember(_ id: Data, key: Data, value: Data) {
        if keys.count >= 128 { keys.removeAll() }; keys[id] = (key, value)
    }
    private static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }; var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }; return difference == 0
    }
    private static func hash(_ data: Data) throws -> Data {
        var output = Data(count: 32)
        let success = output.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                vesper_sha256(
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    output.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
        guard success == 1 else { throw UsenetError.corrupt }; return output
    }
}
