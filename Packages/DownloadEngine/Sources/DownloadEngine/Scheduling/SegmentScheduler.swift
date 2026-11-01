//
//  SegmentScheduler.swift
//  DownloadEngine
//
//  The shared work queue. Hands out segments to pool workers; already-resolved segments (from a
//  resumed checkpoint) are skipped. Each worker fully resolves the segment it pulls (retrying on
//  its own / a fresh connection), so the scheduler stays a simple thread-safe queue — the seam
//  where multi-server failover slots in later (requeue against the next server by priority).
//

import Foundation

actor SegmentScheduler {
    struct WorkItem: Sendable {
        let fileID: String
        let filename: String
        let segment: SegmentSpec
        let totalSegments: Int
    }

    private var pending: [WorkItem]
    private var cursor = 0

    init(files: [FileSpec], resolved: Set<String>) {
        pending = files.flatMap { file in
            file.segments
                .filter { !resolved.contains($0.id) }
                .sorted { $0.number < $1.number }
                .map {
                    WorkItem(
                        fileID: file.id, filename: file.filename, segment: $0,
                        totalSegments: file.segments.count)
                }
        }
    }

    func next() -> WorkItem? {
        guard cursor < pending.count else { return nil }
        defer { cursor += 1 }
        return pending[cursor]
    }

    /// Put a segment back at the end of the queue so another worker (on a fresh connection) can
    /// retry it later. Used when a segment exhausts its per-attempt retries on a transient error —
    /// the alternative (recording it as permanently missing) would corrupt the output on a flaky
    /// link. A per-item requeue budget stops a truly dead segment from looping forever.
    func requeue(_ item: WorkItem) -> Bool {
        let count = (requeues[item.segment.id] ?? 0) + 1
        guard count <= Self.maxRequeues else { return false }
        requeues[item.segment.id] = count
        pending.append(item)
        return true
    }

    private var requeues: [String: Int] = [:]
    private static let maxRequeues = 3

    var remainingCount: Int { max(0, pending.count - cursor) }
    var totalCount: Int { pending.count }
}
