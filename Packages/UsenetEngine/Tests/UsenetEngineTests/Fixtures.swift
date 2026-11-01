import Foundation
import XCTest
@testable import UsenetEngine

let provider = UsenetProvider(host: "news.example.test", username: "user", password: "secret", connections: 1)

func encoded(
    _ data: Data, name: String = "movie.mp4", offset: Int = 0, size: Int? = nil, part: Int = 1, total: Int = 1
) -> [Data] {
    let fullSize = size ?? data.count
    var result = [
        Data("=ybegin part=\(part) total=\(total) line=128 size=\(fullSize) name=\(name)".utf8),
        Data("=ypart begin=\(offset + 1) end=\(offset + data.count)".utf8),
    ]
    var line = Data()
    for byte in data {
        let value = byte &+ 42
        if [0, 10, 13, 61].contains(value) {
            line.append(61); line.append(value &+ 64)
        } else {
            line.append(value)
        }
        if line.count >= 128 { result.append(line); line = Data() }
    }
    if !line.isEmpty { result.append(line) }
    result.append(
        Data(
            "=yend size=\(data.count) part=\(part) pcrc32=\(String(CRC32.checksum(of: data), radix: 16))".utf8
        ))
    return result
}

actor FixtureSource: ArticleSource {
    var articles: [String: [Data]] = [:]
    var requests: [String] = []
    private var inFlight = 0
    private(set) var peakInFlight = 0
    func resetPeak() { peakInFlight = inFlight }
    var failures: [String: [UsenetError]] = [:]
    let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    func add(_ data: Data, id: Int, name: String, chunk: Int = 1024) -> NZBFile {
        let total = (data.count + chunk - 1) / chunk
        let segments = (0..<total).map { index -> NZBSegment in
            let message = "\(id)-\(index)@fixture"
            let start = index * chunk
            articles[message] = encoded(
                data.subdata(in: start..<min(data.count, start + chunk)), name: name, offset: start,
                size: data.count, part: index + 1, total: total)
            return NZBSegment(number: index + 1, messageID: message, encodedBytes: chunk + 200)
        }
        return NZBFile(id: id, name: name, segments: segments)
    }
    func replace(_ id: String, lines: [Data]?) { articles[id] = lines }
    func fail(_ id: String, errors: [UsenetError]) { failures[id] = errors }
    func article(_ messageID: String, priority: ArticlePriority) async throws -> [Data] {
        requests.append(messageID)
        inFlight += 1; peakInFlight = max(peakInFlight, inFlight)
        defer { inFlight -= 1 }
        if delay != .zero { try await Task.sleep(for: delay) }
        if var errors = failures[messageID], !errors.isEmpty {
            let error = errors.removeFirst(); failures[messageID] = errors; throw error
        }
        guard let lines = articles[messageID] else { throw UsenetError.missingArticle }; return lines
    }
    func stop() {}
    func count(_ id: String) -> Int { requests.filter { $0 == id }.count }
}

struct MemoryResource: ByteResource {
    let data: Data
    func size() async throws -> Int64 { Int64(data.count) }
    func read(offset: Int64, count: Int, priority: ArticlePriority) async throws -> Data {
        guard offset >= 0, offset < data.count else { throw UsenetError.invalidRange }
        return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
    }
}
func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("usenet-tests-" + UUID().uuidString)
}
func little(_ value: UInt64, _ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}
func vint(_ value: Int) -> Data {
    var remaining = value, bytes = Data()
    repeat {
        let part = remaining & 127; remaining >>= 7; bytes.append(UInt8(part | (remaining > 0 ? 128 : 0)))
    } while remaining > 0
    return bytes
}
func rar4Block(_ type: UInt8, flags: UInt16 = 0, fields: Data = Data()) -> Data {
    let header = Data([type]) + little(UInt64(flags), 2) + little(UInt64(7 + fields.count), 2) + fields
    return little(UInt64(CRC32.checksum(of: header) & 0xffff), 2) + header
}
func rar4(
    _ data: Data, name: String = "movie.mp4", total: Int? = nil, before: Bool = false, after: Bool = false,
    compressed: Bool = false, encrypted: Bool = false
) -> Data {
    let fields =
        little(UInt64(data.count), 4) + little(UInt64(total ?? data.count), 4) + Data([3])
        + little(UInt64(CRC32.checksum(of: data)), 4) + little(0, 4) + Data([20, compressed ? 0x33 : 0x30])
        + little(UInt64(name.utf8.count), 2) + little(0, 4) + Data(name.utf8)
    let flags: UInt16 = 0x8000 | (before ? 1 : 0) | (after ? 2 : 0) | (encrypted ? 4 : 0)
    return Data([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0])
        + rar4Block(0x73, fields: Data(repeating: 0, count: 6))
        + rar4Block(0x74, flags: flags, fields: fields) + data + rar4Block(0x7b, flags: after ? 1 : 0)
}
func rar5Block(_ fields: Data) -> Data {
    let header = vint(fields.count) + fields
    return little(UInt64(CRC32.checksum(of: header)), 4) + header
}
func rar5(
    _ data: Data, name: String = "movie.mp4", total: Int? = nil, before: Bool = false, after: Bool = false,
    compressed: Bool = false, encrypted: Bool = false
) -> Data {
    let extra = encrypted ? vint(1) + vint(1) : Data()
    let flags = 2 | (before ? 8 : 0) | (after ? 16 : 0) | (encrypted ? 1 : 0)
    var fields = vint(2) + vint(flags)
    if encrypted { fields += vint(extra.count) }
    fields +=
        vint(data.count) + vint(0) + vint(total ?? data.count) + vint(0) + vint(compressed ? 128 : 0)
        + vint(1) + vint(name.utf8.count) + Data(name.utf8) + extra
    return Data([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 1, 0]) + rar5Block(vint(1) + vint(0) + vint(0))
        + rar5Block(fields) + data + rar5Block(vint(5) + vint(0) + vint(after ? 1 : 0))
}

func expectError(
    _ expected: UsenetError, file: StaticString = #filePath, line: UInt = #line,
    operation: () async throws -> Void
) async {
    do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) } catch {
        XCTAssertEqual(error as? UsenetError, expected, file: file, line: line)
    }
}
