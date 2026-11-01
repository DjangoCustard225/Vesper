//
//  EngineModels.swift
//  DownloadEngine
//
//  Public input/output types. The app maps its own `Types/` models onto these so the engine
//  has no dependency on the app target.
//

import Foundation

/// Connection details for one Usenet server.
public struct ServerConfig: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var useSSL: Bool
    public var username: String?
    public var password: String?
    /// Provider's allowed simultaneous connections.
    public var maxConnections: Int
    /// Aggregate download speed cap in bytes/sec across all connections; 0 = unlimited.
    public var bytesPerSecondLimit: Int

    public init(
        host: String, port: Int, useSSL: Bool, username: String?, password: String?,
        maxConnections: Int, bytesPerSecondLimit: Int = 0
    ) {
        self.host = host
        self.port = port
        self.useSSL = useSSL
        self.username = username
        self.password = password
        self.maxConnections = max(1, maxConnections)
        self.bytesPerSecondLimit = max(0, bytesPerSecondLimit)
    }
}

/// One article segment to fetch.
public struct SegmentSpec: Sendable, Identifiable, Equatable {
    public var id: String  // unique within the job (the message-id)
    public var messageID: String  // without surrounding angle brackets
    public var byteCount: Int
    public var number: Int  // 1-based ordering within the file

    public init(id: String, messageID: String, byteCount: Int, number: Int) {
        self.id = id
        self.messageID = messageID
        self.byteCount = byteCount
        self.number = number
    }
}

/// One logical file reconstructed from its ordered segments.
public struct FileSpec: Sendable, Identifiable, Equatable {
    public var id: String
    public var filename: String
    public var groups: [String]
    public var segments: [SegmentSpec]

    public init(id: String, filename: String, groups: [String], segments: [SegmentSpec]) {
        self.id = id
        self.filename = filename
        self.groups = groups
        self.segments = segments
    }

    public var totalBytes: Int { segments.reduce(0) { $0 + $1.byteCount } }
}

/// A complete download job.
public struct JobSpec: Sendable, Identifiable {
    public var id: String
    public var files: [FileSpec]
    /// Directory where `.part` scratch files and the checkpoint are written.
    public var workingDirectory: URL

    public init(id: String, files: [FileSpec], workingDirectory: URL) {
        self.id = id
        self.files = files
        self.workingDirectory = workingDirectory
    }

    public var totalBytes: Int { files.reduce(0) { $0 + $1.totalBytes } }
}

/// Events streamed from the engine while a job runs.
public enum EngineEvent: Sendable {
    /// A segment finished and its bytes were written to disk.
    case segmentCompleted(fileID: String, segmentID: String, decodedBytes: Int)
    /// A segment exhausted retries and was given up on (likely a missing/taken-down article).
    case segmentMissing(fileID: String, segmentID: String, reason: String)
    /// A file's segments are all resolved (downloaded or permanently missing).
    case fileCompleted(fileID: String, url: URL, missingSegments: Int)
    /// Aggregate progress tick (throttled by the engine).
    case progress(downloadedBytes: Int, bytesPerSecond: Int, activeConnections: Int)
    /// The job is parked waiting for connectivity (mobile resilience).
    case waitingForNetwork(Bool)
    /// Terminal: the job finished (all files resolved), was cancelled, or failed to start.
    case finished(EngineResult)
}

public enum EngineResult: Sendable, Equatable {
    /// All files resolved. `missingSegments` > 0 means PAR2 repair may be needed.
    case completed(downloadedBytes: Int, missingSegments: Int)
    case cancelled
    case failed(reason: String)
}
