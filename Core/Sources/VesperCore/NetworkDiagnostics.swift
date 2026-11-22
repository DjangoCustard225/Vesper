import Foundation

public enum NetworkOperation: String, Codable, Sendable {
    case tmdb, tvdb, trakt, manifest, catalog, metadata, streams, artwork
    case indexer
    case introSegments
    case ratings
    case usenetStream
    case traktScrobbleStart, traktScrobblePause, traktScrobbleStop

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .metadata
    }

    var responseByteLimit: Int {
        switch self {
        case .artwork: 30 * 1024 * 1024
        case .tmdb: 7_999_999
        default: 12_000_000
        }
    }
}
public enum DiagnosticOutcome: String, Codable, Sendable { case success, http, timeout, offline, network }
public enum ArtworkStage: String, Codable, Sendable {
    case downloadQueue, preparationQueue, preparation
}

public struct ArtworkTimer: Sendable {
    private let started = ProcessInfo.processInfo.systemUptime
    public init() {}
    public var milliseconds: Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
    }
}

public struct DiagnosticEvent: Codable, Sendable {
    public let date: Date
    public let operation: NetworkOperation
    public let attempt: Int
    public let milliseconds: Int
    public let status: Int?
    public let outcome: DiagnosticOutcome
    public var artworkStage: ArtworkStage? = nil
    public var isPrefetch: Bool? = nil
    public var usenet: UsenetStreamDiagnostics? = nil
}

/// One Usenet playback session's performance. Counts and timings only, never titles or hosts.
public struct UsenetStreamDiagnostics: Codable, Sendable, Equatable {
    /// From opening the video to the player's first completed read.
    public var firstReadMilliseconds: Int?
    public var articles: Int
    public var megabytes: Double
    public var averageArticleMilliseconds: Int
    /// Slow articles requested again on another connection, and how often that copy won.
    public var hedges: Int
    public var hedgeWins: Int
    /// Player reads that waited over a second.
    public var slowReads: Int
    /// Articles moved from memory to disk.
    public var spilled: Int
    /// Connections the provider allowed, after any automatic reduction.
    public var connections: Int
    public var playbackMegabitsPerSecond: Double?

    public init(
        firstReadMilliseconds: Int?, articles: Int, megabytes: Double, averageArticleMilliseconds: Int,
        hedges: Int, hedgeWins: Int, slowReads: Int, spilled: Int, connections: Int,
        playbackMegabitsPerSecond: Double?
    ) {
        self.firstReadMilliseconds = firstReadMilliseconds
        self.articles = articles
        self.megabytes = megabytes
        self.averageArticleMilliseconds = averageArticleMilliseconds
        self.hedges = hedges
        self.hedgeWins = hedgeWins
        self.slowReads = slowReads
        self.spilled = spilled
        self.connections = connections
        self.playbackMegabitsPerSecond = playbackMegabitsPerSecond
    }
}

/// Deliberately accepts no URLs, headers, response bodies, or arbitrary error text.
public actor DiagnosticRecorder {
    public static let shared = DiagnosticRecorder(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VesperDiagnostics"))
    private let directory: URL?
    private var events: [DiagnosticEvent] = []
    private let flushInterval: Duration
    private let batchSize: Int
    private var unsaved = 0
    private var flushTask: Task<Void, Never>?

    public init(directory: URL? = nil, flushInterval: Duration = .seconds(1), batchSize: Int = 20) {
        self.directory = directory
        self.flushInterval = flushInterval
        self.batchSize = max(1, batchSize)
        if let directory,
            let data = try? PersistenceIO.read(
                directory.appendingPathComponent("requests.json"), maximumBytes: 128 * 1024),
            let saved = try? JSONDecoder().decode([DiagnosticEvent].self, from: data)
        {
            events = Array(saved.suffix(200))
        }
    }

    public func record(_ event: DiagnosticEvent) {
        events.append(event)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        guard directory != nil else { return }
        unsaved += 1
        if unsaved >= batchSize {
            flush()
        } else if flushTask == nil {
            let interval = flushInterval
            flushTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: interval)
                    try Task.checkCancellation()
                } catch { return }
                await self?.flush()
            }
        }
    }

    public func recordArtwork(_ stage: ArtworkStage, milliseconds: Int, priority: ArtworkPriority) {
        record(
            DiagnosticEvent(
                date: Date(), operation: .artwork, attempt: 0,
                milliseconds: max(0, milliseconds), status: nil, outcome: .success,
                artworkStage: stage, isPrefetch: priority == .prefetch))
    }

    public func recordUsenet(_ summary: UsenetStreamDiagnostics, milliseconds: Int) {
        var event = DiagnosticEvent(
            date: Date(), operation: .usenetStream, attempt: 0, milliseconds: max(0, milliseconds),
            status: nil, outcome: .success)
        event.usenet = summary
        record(event)
    }

    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard unsaved > 0 else { return }
        guard let directory, let data = try? JSONEncoder().encode(events) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PersistenceIO.write(data, directory.appendingPathComponent("requests.json"))
            unsaved = 0
        } catch { /* Diagnostics must not interrupt browsing; retry on the next batch or flush. */  }
    }

    public func export() throws -> Data {
        flush()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(events)
    }
}
