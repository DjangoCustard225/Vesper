import Foundation

public enum DownloadPhase: String, Codable, Sendable {
    case queued, preparing, downloading, pausing, paused, failed, completed
    public var isActive: Bool { self == .preparing || self == .downloading || self == .pausing }
}

public struct DownloadRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public var media: MediaItem
    public let videoID: String
    public var subtitle: String?
    public var episode: Episode?
    public var source: StreamSource
    public let providerID: String?
    public var fetchedAt: Date
    public let createdAt: Date
    public var phase: DownloadPhase = .queued
    public var attempt = UUID()
    public var expectedBytes: Int64?
    public var receivedBytes: Int64 = 0
    public var fileName: String?
    public var message: String?
    public var resumeData: Data?
    public var resumeAllowsCellular = false
    public var etag: String?
    public var lastModified: String?
    public var retryCount = 0
    public var retryAt: Date?
    public var artwork: [String: String] = [:]
    public var httpParallel: Bool? = nil
    public var httpWasResuming: Bool? = nil
    public var httpResumeRecoveries: Int? = nil
    public var httpAuthRetries: Int? = nil
    public var httpRefreshSource: Bool? = nil
    public var usenetSelectedFile: String? = nil
    public var usenetFiles: [String]? = nil
    public var usenetNeedsPassword: Bool? = nil
    public var usenetFinishing: Bool? = nil
    public var detailArtwork: DetailArtwork? = nil
    public var artworkURLs: [String] {
        [media.poster, media.background, episode?.thumbnail].compactMap { $0 } + (detailArtwork?.urls ?? [])
    }

    public init(
        media: MediaItem, videoID: String, subtitle: String?, episode: Episode?, source: StreamSource,
        providerID: String?, fetchedAt: Date, id: UUID = UUID()
    ) {
        self.id = id
        var snapshot = media
        snapshot.videos = nil
        snapshot.behaviorHints = nil
        self.media = snapshot
        self.videoID = videoID
        self.subtitle = subtitle
        self.episode = episode.map(Self.snapshot)
        self.source = source
        self.providerID = providerID
        self.fetchedAt = fetchedAt
        createdAt = Date()
        expectedBytes = source.behaviorHints?.videoSize.flatMap { $0 > 0 ? $0 : nil }
    }

    public func duplicates(_ other: DownloadRecord) -> Bool {
        media.isSameTitle(as: other.media)
            && (media.type == "movie" || videoID == other.videoID
                || (episode?.season != nil && episode?.episode != nil
                    && episode?.season == other.episode?.season
                    && episode?.episode == other.episode?.episode))
            && (StreamPolicy.identity(source) == StreamPolicy.identity(other.source)
                || StreamPolicy.refreshedMatch(for: source, in: [other.source]) != nil)
    }

    private static func snapshot(_ episode: Episode) -> Episode {
        Episode(
            id: episode.id, title: episode.title, name: episode.name, season: episode.season,
            episode: episode.episode, overview: episode.overview, thumbnail: episode.thumbnail,
            released: episode.released, streams: nil, runtimeMinutes: episode.runtimeMinutes)
    }
}

public struct DownloadLibrary: Codable, Sendable {
    public var version = 1
    public var allowsCellular = false
    public var records: [DownloadRecord] = []
    public init() {}
}

public enum DownloadFailure: LocalizedError {
    case unsupported, response, incomplete, storage, unreadable, futureVersion, missing
    public var errorDescription: String? {
        switch self {
        case .unsupported: "This source is not a downloadable video file. Choose a direct file source."
        case .response:
            "The source did not return a video file. It may still be preparing or its link may have expired."
        case .incomplete: "The downloaded file is incomplete. Retry this download."
        case .storage: "Not enough storage. Free some space and retry."
        case .unreadable: "The downloads index could not be read. Your files have been preserved."
        case .futureVersion:
            "These downloads were saved by a newer version of Vesper. Your files have been preserved."
        case .missing: "This downloaded file is missing. Download it again or remove its entry."
        }
    }
}

public enum DownloadPolicy {
    public static let parallelLimit = 2
    public static let storageReserve: Int64 = 512 * 1024 * 1024

    public static func supportsUsenet(_ source: StreamSource, live: Bool = false) -> Bool {
        guard !live, source.nzbUrl != nil else { return false }
        if case .usenet = try? StreamResolver.resolve(source) { return true }
        return false
    }

    public static func url(for source: StreamSource, live: Bool = false) throws -> URL {
        guard !live, source.externalUrl == nil, source.ytId == nil,
            case .native(let url) = try StreamResolver.resolve(source),
            !["m3u", "m3u8", "mpd"].contains(url.pathExtension.lowercased())
        else { throw DownloadFailure.unsupported }
        return url
    }

    public static func validate(status: Int, mime: String?, prefix: Data) throws {
        guard status == 200 || status == 206 else { throw DownloadFailure.response }
        let mime = (mime ?? "").lowercased()
        guard !["mpegurl", "dash+xml", "text/", "json", "html"].contains(where: mime.contains) else {
            throw DownloadFailure.unsupported
        }
        if let text = String(data: prefix.prefix(4096), encoding: .utf8)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).lowercased(),
            text.hasPrefix("#extm3u") || text.hasPrefix("<") || text.hasPrefix("{") || text.hasPrefix("[")
        {
            throw DownloadFailure.response
        }
    }

    public static func totalBytes(contentRange: String?, contentLength: Int64) -> Int64? {
        if let total = contentRange?.split(separator: "/").last.flatMap({ Int64($0) }), total > 0 {
            return total
        }
        return contentRange == nil && contentLength > 0 ? contentLength : nil
    }

    public static func isOutOfSpace(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<5 {
            guard let value = current else { break }
            if value.domain == NSCocoaErrorDomain && value.code == NSFileWriteOutOfSpaceError { return true }
            if value.domain == NSPOSIXErrorDomain && value.code == Int(POSIXError.ENOSPC.rawValue) {
                return true
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Reserve only data still to be received. Later phases check their own space needs.
    public static func usenetBytesRemaining(total: Int64, received: Int64) -> Int64 {
        let total = max(0, total)
        return total - min(total, max(0, received))
    }

    public static func hasSpace(available: Int64, remaining: [Int64]) -> Bool {
        var needed = storageReserve
        for bytes in remaining where bytes > 0 {
            let sum = needed.addingReportingOverflow(bytes)
            guard !sum.overflow else { return false }
            needed = sum.partialValue
        }
        return available >= needed
    }

    public static func next(_ records: [DownloadRecord], now: Date = Date(), networkAllowed: Bool = true)
        -> [DownloadRecord]
    {
        guard networkAllowed else { return [] }
        let slots = max(0, parallelLimit - records.filter { $0.phase.isActive }.count)
        return Array(
            records.filter { $0.phase == .queued && ($0.retryAt ?? .distantPast) <= now }.prefix(slots))
    }

    public static func canResume(
        _ record: DownloadRecord, source: StreamSource, allowsCellular: Bool,
        etag: String?, modified: String?, total: Int64?
    ) -> Bool {
        let same = record.etag.map { $0 == etag } ?? record.lastModified.map { $0 == modified } ?? false
        return record.resumeData != nil && record.source.url == source.url
            && record.resumeAllowsCellular == allowsCellular
            && same && (record.expectedBytes == nil || total == nil || record.expectedBytes == total)
    }

    public static func recovered(_ record: DownloadRecord, hasTask: Bool, hasFile: Bool) -> DownloadRecord {
        var value = record
        if value.phase.isActive && !hasTask && value.usenetFinishing == true {
            value.phase = .failed
            value.message = "Finishing this release was interrupted. Resume to verify and extract it again."
        } else if value.phase.isActive && !hasTask {
            value.phase = value.phase == .pausing ? .paused : .queued
            value.message = "Recovering interrupted download"
        }
        if value.phase == .completed && !hasFile {
            value.phase = .failed
            value.message = DownloadFailure.missing.localizedDescription
        }
        return value
    }

    public static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }

    public static func fileExtension(url: URL, filename: String?, mime: String?, prefix: Data) -> String {
        let allowed = Set(["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mpg", "mpeg"])
        for value in [filename.map { ($0 as NSString).pathExtension }, url.pathExtension].compactMap({ $0 }) {
            if allowed.contains(value.lowercased()) { return value.lowercased() }
        }
        if prefix.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return "mkv" }
        if prefix.count >= 8, String(data: prefix.dropFirst(4).prefix(4), encoding: .ascii) == "ftyp" {
            return "mp4"
        }
        if mime?.contains("mp4") == true { return "mp4" }
        return "media"
    }
}

/// A versioned index; media files and cached artwork are owned separately by the app adapter.
public struct DownloadRepository: Sendable {
    public let url: URL
    private let write: @Sendable (Data, URL) throws -> Void
    public init(url: URL) { self.init(url: url, write: { try PersistenceIO.write($0, $1) }) }
    public init(url: URL, write: @escaping @Sendable (Data, URL) throws -> Void) {
        self.url = url; self.write = write
    }

    public func load() throws -> DownloadLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return DownloadLibrary() }
        do {
            let data = try PersistenceIO.read(url, maximumBytes: 32 * 1024 * 1024)
            let library = try JSONDecoder().decode(DownloadLibrary.self, from: data)
            guard library.version == 1 else { throw DownloadFailure.futureVersion }
            try Self.validate(library)
            return library
        } catch DownloadFailure.futureVersion { throw DownloadFailure.futureVersion } catch {
            throw DownloadFailure.unreadable
        }
    }

    public func save(_ library: DownloadLibrary) throws {
        try Self.validate(library)
        let data = try JSONEncoder().encode(library)
        guard data.count <= 32 * 1024 * 1024 else { throw DownloadFailure.unreadable }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(data, url)
        try PersistenceIO.excludeFromBackup(url)
    }

    private static func validate(_ library: DownloadLibrary) throws {
        guard library.version == 1, library.records.count <= 1000,
            Set(library.records.map(\.id)).count == library.records.count,
            library.records.allSatisfy({ record in
                !record.videoID.isEmpty && !record.media.id.isEmpty && record.receivedBytes >= 0
                    && (record.expectedBytes.map { $0 > 0 } ?? true)
                    && (record.fileName.map(DownloadPolicy.safeName) ?? true)
                    && record.artwork.values.allSatisfy(DownloadPolicy.safeName)
                    && (record.phase != .completed || record.fileName != nil)
            })
        else { throw DownloadFailure.unreadable }
    }
}

/// A file may be in use by playback and a share operation at the same time.
public struct DownloadFileLeases {
    private var counts: [UUID: Int] = [:]
    public var ids: Set<UUID> { Set(counts.keys) }
    public init() {}
    public mutating func acquire(_ ids: Set<UUID>) { for id in ids { counts[id, default: 0] += 1 } }
    public mutating func release(_ ids: Set<UUID>) {
        for id in ids {
            if let count = counts[id], count > 1 { counts[id] = count - 1 } else { counts[id] = nil }
        }
    }
}

extension Episode {
    public func offlineSnapshot(thumbnail: String?) -> Episode {
        Episode(
            id: id, title: title, name: name, season: season, episode: episode, overview: overview,
            thumbnail: thumbnail, released: released, streams: nil, runtimeMinutes: runtimeMinutes)
    }
}

public struct DownloadTaskKey: Sendable {
    public let id: UUID
    public let attempt: UUID
    public var description: String { id.uuidString + "/" + attempt.uuidString }
    public init(id: UUID, attempt: UUID) { self.id = id; self.attempt = attempt }
    public init?(_ value: String?) {
        let parts = value?.split(separator: "/") ?? []
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
            let attempt = UUID(uuidString: String(parts[1]))
        else { return nil }
        self.init(id: id, attempt: attempt)
    }
}

public struct DownloadReceipt: Sendable {
    public let location: URL
    public let status: Int
    public let mime: String?
    public let total: Int64?
    public init(location: URL, status: Int, mime: String?, total: Int64?) {
        self.location = location; self.status = status; self.mime = mime; self.total = total
    }
}

public enum DownloadPlayback {
    public static func matches(
        _ record: DownloadRecord, media: MediaItem, videoID: String, episode: Episode? = nil
    ) -> Bool {
        guard record.phase == .completed, record.media.isSameTitle(as: media) else { return false }
        if media.type == "movie" { return true }
        if let season = episode?.season, let number = episode?.episode,
            let saved = record.episode, saved.season == season, saved.episode == number
        {
            return true
        }
        let ids = [record.videoID, record.episode?.id, record.episode?.watchHistoryID(for: media)].compactMap
        { $0 }
        return ids.contains {
            MediaIdentity.videoID($0, for: media) == MediaIdentity.videoID(videoID, for: media)
        }
    }

    /// Cached downloads must not make a missing episode look like a season boundary.
    public static func next(
        after current: Episode, known: [Episode], downloaded: [DownloadRecord], media: MediaItem,
        isWatched: (Episode) -> Bool
    ) -> Episode? {
        guard let season = current.season, let number = current.episode else { return nil }
        let ordered = known.filter { episode in
            guard let s = episode.season, let n = episode.episode else { return false }
            return (season == 0 ? s == 0 : s >= season && s > 0) && (s > season || n > number)
        }.sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        let expectedSeason = season
        var expectedNumber = number + 1
        var seen = Set<String>()
        for episode in ordered {
            guard let s = episode.season, let n = episode.episode else { continue }
            guard seen.insert("\(s):\(n)").inserted else { continue }
            // Without a full cached season boundary, stop rather than skipping an unknown episode.
            guard s == expectedSeason, n == expectedNumber else { return nil }
            expectedNumber += 1
            if isWatched(episode) { continue }
            return downloaded.contains { matches($0, media: media, videoID: episode.id, episode: episode) }
                ? episode : nil
        }
        return nil
    }

    public static func exportName(_ record: DownloadRecord, ext: String) -> String {
        let episode =
            record.episode.flatMap { ep -> String? in
                guard let s = ep.season, let n = ep.episode else { return nil }
                return String(format: " S%02dE%02d", s, n)
            } ?? ""
        let name = (record.media.name + episode).components(
            separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t").union(.controlCharacters)
        ).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? "Video" : name).prefix(160)) + "." + ext
    }
}
