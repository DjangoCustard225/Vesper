import Testing
import Foundation
import CryptoKit
@testable import PAR2Kit

/// Files arrive under whatever name the article or NZB subject gave them, which is routinely
/// obfuscated or mangled. PAR2 knows the real name and can prove a match from the first 16 KB.
struct NameRestorationTests {
    // MARK: - Minimal PAR2 writer (Main + FileDescription packets)

    private func packet(type: String, body: [UInt8], setID: [UInt8]) -> [UInt8] {
        var typeField = Array(type.utf8)
        typeField += [UInt8](repeating: 0, count: 16 - typeField.count)
        let signed = setID + typeField + body
        let length = UInt64(64 + body.count)
        var bytes = Array("PAR2\0PKT".utf8)
        bytes += (0..<8).map { UInt8((length >> (8 * UInt64($0))) & 0xFF) }
        bytes += Array(Insecure.MD5.hash(data: Data(signed)))
        bytes += signed
        return bytes
    }

    private func u64(_ value: Int) -> [UInt8] {
        (0..<8).map { UInt8((UInt64(value) >> (8 * UInt64($0))) & 0xFF) }
    }
    private func u32(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8((UInt32(value) >> (8 * UInt32($0))) & 0xFF) }
    }

    /// A `.par2` describing one file of `length` bytes named `name`, whose 16k hash is `md5_16k`.
    private func par2(name: String, length: Int, md5_16k: [UInt8], in dir: URL) -> URL {
        let setID = [UInt8](repeating: 0xAB, count: 16)
        let fileID = [UInt8](repeating: 0x11, count: 16)
        var nameBytes = Array(name.utf8)
        while nameBytes.count % 4 != 0 { nameBytes.append(0) }  // packets are 4-byte aligned

        var bytes = packet(type: "PAR 2.0\0Main", body: u64(4) + u32(1) + fileID, setID: setID)
        bytes += packet(
            type: "PAR 2.0\0FileDesc",
            body: fileID + [UInt8](repeating: 0x22, count: 16) + md5_16k + u64(length) + nameBytes,
            setID: setID)

        let url = dir.appendingPathComponent("recovery.par2")
        try? Data(bytes).write(to: url)
        return url
    }

    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("par2-rename-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Tests

    @Test func renamesAMisnamedFileToTheNamePar2Records() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("a perfectly good ebook".utf8)
        try payload.write(to: dir.appendingPathComponent("S."))  // what an unquoted subject yields
        let par2URL = par2(
            name: "A Real Book.epub", length: payload.count,
            md5_16k: Array(Insecure.MD5.hash(data: payload)), in: dir)

        let renames = PAR2Job(par2URLs: [par2URL], directory: dir).restoreNames()

        #expect(renames.map(\.from) == ["S."])
        #expect(renames.map(\.to) == ["A Real Book.epub"])
        #expect(try Data(contentsOf: dir.appendingPathComponent("A Real Book.epub")) == payload)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("S.").path))
    }

    @Test func leavesAFileWhoseContentDoesNotMatchAlone() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("a perfectly good ebook".utf8)
        // Same length, different bytes — a name collision must not move it.
        try Data(String(repeating: "x", count: payload.count).utf8)
            .write(to: dir.appendingPathComponent("unrelated.bin"))
        let par2URL = par2(
            name: "A Real Book.epub", length: payload.count,
            md5_16k: Array(Insecure.MD5.hash(data: payload)), in: dir)

        #expect(PAR2Job(par2URLs: [par2URL], directory: dir).restoreNames().isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("unrelated.bin").path))
    }

    @Test func leavesCorrectlyNamedOutputUntouched() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("already fine".utf8)
        try payload.write(to: dir.appendingPathComponent("A Real Book.epub"))
        let par2URL = par2(
            name: "A Real Book.epub", length: payload.count,
            md5_16k: Array(Insecure.MD5.hash(data: payload)), in: dir)

        #expect(PAR2Job(par2URLs: [par2URL], directory: dir).restoreNames().isEmpty)
    }
}
