//
//  CheckpointStore.swift
//  DownloadEngine
//
//  Persists which segments are done / permanently missing so a job survives app suspension or
//  relaunch and resumes without re-downloading. The on-disk `.part` files are authoritative; the
//  checkpoint is a fast index that lets the scheduler skip resolved work. Writes are atomic and
//  debounced.
//

import Foundation

/// Serializable resume state for one job.
public struct Checkpoint: Codable, Sendable {
    public var jobID: String
    public var completedSegmentIDs: Set<String>
    public var missingSegmentIDs: Set<String>
    public var finalizedFilenames: [String: String]
    public var decodedSizes: [String: Int]

    public init(
        jobID: String, completedSegmentIDs: Set<String> = [], missingSegmentIDs: Set<String> = [],
        finalizedFilenames: [String: String] = [:], decodedSizes: [String: Int] = [:]
    ) {
        self.jobID = jobID
        self.completedSegmentIDs = completedSegmentIDs
        self.missingSegmentIDs = missingSegmentIDs
        self.finalizedFilenames = finalizedFilenames
        self.decodedSizes = decodedSizes
    }

    private enum CodingKeys: String, CodingKey {
        case jobID, completedSegmentIDs, missingSegmentIDs, finalizedFilenames, decodedSizes
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try values.decode(String.self, forKey: .jobID)
        completedSegmentIDs = try values.decode(Set<String>.self, forKey: .completedSegmentIDs)
        missingSegmentIDs = try values.decode(Set<String>.self, forKey: .missingSegmentIDs)
        finalizedFilenames =
            try values.decodeIfPresent([String: String].self, forKey: .finalizedFilenames) ?? [:]
        decodedSizes = try values.decodeIfPresent([String: Int].self, forKey: .decodedSizes) ?? [:]
    }

    /// Segments already resolved (won't be re-fetched).
    public var resolvedSegmentIDs: Set<String> { completedSegmentIDs.union(missingSegmentIDs) }
}

actor CheckpointStore {
    private let url: URL
    private var pendingSaveTask: Task<Void, Never>?
    private var lastWrite: ContinuousClock.Instant?
    private static let debounce: Duration = .seconds(2)
    /// Even under a steady stream of completions (which keep resetting the debounce), never let
    /// the on-disk checkpoint fall more than this far behind — otherwise a mid-download kill
    /// re-downloads everything since the last quiet period.
    private static let maxStaleness: Duration = .seconds(10)

    init(directory: URL, jobID: String) {
        self.url = directory.appendingPathComponent("checkpoint.json")
    }

    func load() -> Checkpoint? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Checkpoint.self, from: data)
    }

    /// Coalesced save: writes after a short quiet period, but forces a write if the checkpoint has
    /// gone stale (so continuous progress still persists roughly every `maxStaleness`).
    func scheduleSave(_ checkpoint: Checkpoint) {
        let now = ContinuousClock().now
        if let last = lastWrite, now - last >= Self.maxStaleness {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            writeNow(checkpoint)
            return
        }
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.writeNow(checkpoint)
        }
    }

    /// Immediate flush (call on pause / wind-down / backgrounding before suspension).
    func flush(_ checkpoint: Checkpoint) {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        writeNow(checkpoint)
    }

    private func writeNow(_ checkpoint: Checkpoint) {
        lastWrite = ContinuousClock().now
        Self.write(checkpoint, to: url)
    }

    private static func write(_ checkpoint: Checkpoint, to url: URL) {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
