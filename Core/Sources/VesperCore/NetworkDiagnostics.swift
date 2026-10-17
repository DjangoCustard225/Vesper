import Foundation

public enum NetworkOperation: String, Codable, Sendable {
    case tmdb, trakt, manifest, catalog, metadata, streams, artwork
    #if !VESPER_GO
    case traktScrobbleStart, traktScrobblePause, traktScrobbleStop
    #endif

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

public struct DiagnosticEvent: Codable, Sendable {
    public let date: Date
    public let operation: NetworkOperation
    public let attempt: Int
    public let milliseconds: Int
    public let status: Int?
    public let outcome: DiagnosticOutcome
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
