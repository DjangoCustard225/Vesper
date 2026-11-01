import Foundation

public enum UsenetError: Error, LocalizedError, Equatable, Sendable {
    case invalidNZB, unsupported, encrypted, compressed, missingArticle, corrupt, authentication, connection,
        timeout, cancelled, storage, invalidRange, noVideo, providerRequired, badPassword
    public var errorDescription: String? {
        switch self {
        case .invalidNZB: "This NZB is invalid, incomplete or too large."
        case .unsupported:
            "This release uses an unsupported archive layout. Choose raw video or a supported stored RAR release."
        case .encrypted: "This encrypted release did not include an archive password. Choose another release."
        case .badPassword:
            "The passwords supplied with this release could not unlock it. Choose another release."
        case .compressed:
            "Compressed archives are not supported in this test build. Choose a stored RAR release."
        case .missingArticle: "Required articles are unavailable on this provider. Choose another release."
        case .corrupt: "The provider returned corrupt or inconsistent data. Choose another release."
        case .authentication: "The Usenet provider rejected the login. Check the provider details."
        case .connection: "The Usenet connection failed. Check the network and provider details."
        case .timeout: "The Usenet provider did not respond in time. Try again."
        case .cancelled: "Usenet playback was stopped."
        case .storage: "The streaming cache could not be saved. Free some storage and retry."
        case .invalidRange: "The requested video range is unavailable."
        case .noVideo: "No supported video was found in this NZB."
        case .providerRequired: "Add a TLS Usenet provider in Settings or configure the add-on to supply one."
        }
    }
}

public struct UsenetProvider: Codable, Sendable, Equatable {
    public static let connectionRange = 1...100
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var connections: Int
    public init(host: String, port: Int = 563, username: String, password: String, connections: Int = 8) {
        self.host = host; self.port = port; self.username = username; self.password = password;
        self.connections = connections
    }
    public func validated() throws -> UsenetProvider {
        guard !host.isEmpty, host.utf8.count <= 253,
            !host.contains(where: { $0.isWhitespace || "/\\@".contains($0) }),
            (1...65535).contains(port), Self.connectionRange.contains(connections),
            [username, password].allSatisfy({
                $0.utf8.count <= 4096 && !$0.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" })
            })
        else { throw UsenetError.providerRequired }
        return self
    }
    public static func from(server: String, limit: Int = 8) throws -> UsenetProvider {
        guard let parts = URLComponents(string: server), parts.scheme?.lowercased() == "nntps",
            let host = parts.host, parts.query == nil, parts.fragment == nil
        else { throw UsenetError.providerRequired }
        let count = parts.path.isEmpty || parts.path == "/" ? limit : (Int(parts.path.dropFirst()) ?? 0)
        return try UsenetProvider(
            host: host, port: parts.port ?? 563, username: parts.user ?? "", password: parts.password ?? "",
            connections: min(limit, count)
        ).validated()
    }
}

public enum ArticlePriority: Int, Sendable { case prefetch = 0, download = 5, playback = 10 }
public protocol ArticleSource: Sendable {
    func article(_ messageID: String, priority: ArticlePriority) async throws -> [Data]
    func promote(_ messageID: String) async
    func stop() async
}
extension ArticleSource { public func promote(_ messageID: String) async {} }

public struct NZBSegment: Sendable, Equatable {
    public let number: Int
    public let messageID: String
    public let encodedBytes: Int
    public init(number: Int, messageID: String, encodedBytes: Int) {
        self.number = number; self.messageID = messageID; self.encodedBytes = encodedBytes
    }
}
public struct NZBFile: Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let segments: [NZBSegment]
    public init(id: Int, name: String, segments: [NZBSegment]) {
        self.id = id; self.name = name; self.segments = segments
    }
}
public struct NZBManifest: Sendable {
    public let title: String?
    public let files: [NZBFile]
    public let passwords: [String]
    public var password: String? { passwords.first }
    public init(title: String? = nil, files: [NZBFile], password: String? = nil, passwords: [String] = []) {
        self.title = title; self.files = files
        self.passwords = ArchivePasswords.candidates(
            explicit: (password.map { [$0] } ?? []) + passwords, names: [title].compactMap { $0 })
    }
}

public struct VideoExtent: Sendable, Equatable {
    public let fileID: Int
    public let offset: Int64
    public let length: Int64
    public init(fileID: Int, offset: Int64, length: Int64) {
        self.fileID = fileID; self.offset = offset; self.length = length
    }
}
public struct UsenetVideo: Sendable, Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let extents: [VideoExtent]
    let cipher: RARCipher?
    let plainLength: Int64?
    public var length: Int64 { plainLength ?? extents.reduce(0) { $0 + $1.length } }
    public var mimeType: String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "m4v", "mov": "video/mp4"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "ts", "m2ts": "video/mp2t"
        default: "application/octet-stream"
        }
    }
    public init(id: Int, name: String, extents: [VideoExtent]) {
        self.id = id; self.name = name; self.extents = extents; cipher = nil; plainLength = nil
    }
    init(id: Int, name: String, extents: [VideoExtent], cipher: RARCipher?, plainLength: Int64?) {
        self.id = id; self.name = name; self.extents = extents; self.cipher = cipher;
        self.plainLength = plainLength
    }
    public static func isVideo(_ name: String) -> Bool {
        ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts", "mpg", "mpeg"].contains(
            (name as NSString).pathExtension.lowercased())
    }
}

func checkedAdd(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (result, overflow) = a.addingReportingOverflow(b)
    guard !overflow, result >= 0, result <= 1 << 50 else { throw UsenetError.corrupt }; return result
}
