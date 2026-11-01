import Foundation

public struct HTTPByteRange: Sendable, Equatable {
    public let start: Int64
    public let end: Int64
    public var count: Int64 { end - start + 1 }
    public static func resolve(_ header: String?, size: Int64) throws -> HTTPByteRange {
        guard size > 0 else { throw UsenetError.invalidRange }
        guard let header else { return HTTPByteRange(start: 0, end: size - 1) }
        guard header.hasPrefix("bytes="), !header.contains(",") else { throw UsenetError.invalidRange }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw UsenetError.invalidRange }
        if parts[0].isEmpty {
            guard let suffix = Int64(parts[1]), suffix > 0 else { throw UsenetError.invalidRange }
            return HTTPByteRange(start: max(0, size - suffix), end: size - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < size else { throw UsenetError.invalidRange }
        let end: Int64
        if parts[1].isEmpty {
            end = size - 1
        } else {
            guard let value = Int64(parts[1]), value >= start else { throw UsenetError.invalidRange };
            end = min(value, size - 1)
        }
        return HTTPByteRange(start: start, end: end)
    }
}

struct LocalHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    init(_ data: Data) throws {
        guard data.count <= 16 * 1024, let text = String(data: data, encoding: .utf8),
            text.hasSuffix("\r\n\r\n")
        else { throw UsenetError.invalidRange }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0",
            ["GET", "HEAD"].contains(String(first[0]))
        else { throw UsenetError.invalidRange }
        method = String(first[0]); path = String(first[1])
        var result: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw UsenetError.invalidRange }
            let name = line[..<colon].lowercased(),
                value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard result[name] == nil else { throw UsenetError.invalidRange }; result[name] = value
        }
        headers = result
    }
}
