//
//  NZBDownloadEngine.swift
//  DownloadEngine
//
//  Orchestrates one job: a fixed pool of `maxConnections` workers (each owning an NNTPConnection)
//  pull segments from the SegmentScheduler, fetch + yEnc-decode + CRC-check them, and stream the
//  bytes to disk via the FileAssembler. Progress + completion are reported through an AsyncStream
//  of `EngineEvent`. Resume is automatic via the CheckpointStore.
//
//  Pause/resume is implemented at the app layer as cancel + re-run: a new run loads the checkpoint
//  and skips resolved segments, so this type only needs start + cancel.
//
//  Failure policy (the state-integrity invariant): a segment is recorded as permanently `missing`
//  ONLY when the server says the article is genuinely gone (430/423/420) or its bytes are durably
//  corrupt (persistent CRC/decode failure). Transient conditions — timeouts, dropped sockets, a
//  cell dead-zone — are requeued and, if still unresolved when the run ends, fail the job as
//  RETRYABLE without poisoning the checkpoint, so resuming re-fetches them. A flaky link degrades
//  throughput; it never bakes a hole into the output.
//

import Foundation

public actor NZBDownloadEngine {
    private let makeConnection: @Sendable (ServerConfig, RateLimiter?) -> any DownloadConnection
    public init() {
        makeConnection = { NNTPConnection(config: $0, rateLimiter: $1) }
    }
    init(makeConnection: @escaping @Sendable (ServerConfig, RateLimiter?) -> any DownloadConnection) {
        self.makeConnection = makeConnection
    }

    private var currentTask: Task<Void, Never>?

    // Per-run state (single job at a time).
    private var emit: (@Sendable (EngineEvent) -> Void)?
    private var jobID = ""
    private var workingDir: URL?
    private var assembler: FileAssembler?
    private var checkpointStore: CheckpointStore?
    private var filesByID: [String: FileSpec] = [:]

    private var downloadedBytes = 0
    private var bytesAtLastTick = 0
    private var smoothedBytesPerSecond = 0.0
    private var activeConnections = 0
    private var authenticated = false
    private var completed: Set<String> = []
    private var missing: Set<String> = []
    private var transientlyFailed: Set<String> = []
    private var authFailureReason: String?
    private var perFileTotal: [String: Int] = [:]
    private var perFileResolved: [String: Int] = [:]
    private var perFileMissing: [String: Int] = [:]
    private var finalizedFiles: Set<String> = []
    private var finalizedNames: [String: String] = [:]
    private var storageFailureReason: String?
    private var decodedSizes: [String: Int] = [:]

    private static let maxAttemptsPerSegment = 5
    private static let fetchTimeout: Double = 30

    // MARK: - Public API

    /// Start (or resume) a job. The returned stream yields progress and finishes with `.finished`.
    /// Cancelling the task that consumes the stream (or calling `cancel()`) stops the job.
    public func run(job: JobSpec, server: ServerConfig, fallbackServers: [ServerConfig] = []) -> AsyncStream<
        EngineEvent
    > {
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream()
        let task = Task { [weak self] in
            await self?.execute(job: job, server: server, fallbackServers: fallbackServers) {
                continuation.yield($0)
            }
            continuation.finish()
        }
        currentTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func cancel() {
        currentTask?.cancel()
    }

    public func cancelAndWait() async {
        currentTask?.cancel()
        await currentTask?.value
    }

    /// Persist the current checkpoint immediately. Call before the app suspends so an interrupted
    /// download resumes from the latest state instead of the last debounced write.
    public func flushCheckpoint() async {
        guard let checkpointStore else { return }
        await checkpointStore.flush(
            Checkpoint(
                jobID: jobID, completedSegmentIDs: completed, missingSegmentIDs: missing,
                finalizedFilenames: finalizedNames, decodedSizes: decodedSizes))
    }

    // MARK: - Orchestration

    private func execute(
        job: JobSpec, server: ServerConfig, fallbackServers: [ServerConfig],
        emit: @escaping @Sendable (EngineEvent) -> Void
    ) async {
        resetState()
        self.emit = emit
        self.jobID = job.id
        self.workingDir = job.workingDirectory
        self.filesByID = Dictionary(uniqueKeysWithValues: job.files.map { ($0.id, $0) })

        let assembler = FileAssembler(directory: job.workingDirectory)
        let checkpointStore = CheckpointStore(directory: job.workingDirectory, jobID: job.id)
        self.assembler = assembler
        self.checkpointStore = checkpointStore

        let saved = await checkpointStore.load()
        let checkpoint = saved?.jobID == job.id ? saved! : Checkpoint(jobID: job.id)
        finalizedNames = checkpoint.finalizedFilenames
        decodedSizes = checkpoint.decodedSizes
        completed = checkpoint.completedSegmentIDs
        missing = checkpoint.missingSegmentIDs
        for file in job.files {
            let name = finalizedNames[file.id] ?? file.filename
            let final = job.workingDirectory.appendingPathComponent(FileAssembler.sanitized(name))
            let part = job.workingDirectory.appendingPathComponent(FileAssembler.sanitized(file.id) + ".part")
            if !FileManager.default.fileExists(atPath: final.path),
                !FileManager.default.fileExists(atPath: part.path)
            {
                let ids = Set(file.segments.map(\.id))
                completed.subtract(ids); missing.subtract(ids); finalizedNames[file.id] = nil
            } else if FileManager.default.fileExists(atPath: part.path), decodedSizes[file.id] == nil,
                let first = file.segments.first
            {
                // Old checkpoints did not persist the true decoded length. Re-read a header
                // rather than finalizing a sparse file at its encoded, padded capacity.
                completed.remove(first.id); missing.remove(first.id)
            }
        }
        for file in job.files where file.segments.contains(where: { missing.contains($0.id) }) {
            let final = job.workingDirectory.appendingPathComponent(
                FileAssembler.sanitized(finalizedNames[file.id] ?? file.filename))
            let part = job.workingDirectory.appendingPathComponent(FileAssembler.sanitized(file.id) + ".part")
            if FileManager.default.fileExists(atPath: final.path),
                !FileManager.default.fileExists(atPath: part.path)
            {
                do { try FileManager.default.moveItem(at: final, to: part) } catch {
                    emit(
                        .finished(
                            .failed(
                                reason: "The partial file could not be reopened. Free storage and resume.")));
                    return
                }
            }
        }
        // Retry missing articles on an explicit resume, including newly configured fallback servers.
        missing.removeAll()
        let resolved = completed

        // Seed counters + scratch files from the checkpoint.
        for file in job.files {
            perFileTotal[file.id] = file.segments.count
            perFileResolved[file.id] = file.segments.filter { resolved.contains($0.id) }.count
            perFileMissing[file.id] = file.segments.filter { missing.contains($0.id) }.count
            downloadedBytes += file.segments
                .filter { completed.contains($0.id) }
                .reduce(0) { $0 + $1.byteCount }
            do {
                let alreadyComplete = try await assembler.prepare(
                    fileID: file.id, filename: finalizedNames[file.id] ?? file.filename,
                    totalBytes: file.totalBytes, decodedSize: decodedSizes[file.id])
                // A file finalized in a previous run must not be re-created/re-finalized (that
                // would zero-clobber good output).
                if alreadyComplete { finalizedFiles.insert(file.id) }
            } catch {
                emit(
                    .finished(
                        .failed(reason: "Couldn't create the scratch file: \(error.localizedDescription)")))
                return
            }
        }
        bytesAtLastTick = downloadedBytes

        let rateLimiter = RateLimiter(bytesPerSecond: server.bytesPerSecondLimit)
        let fallbacks = fallbackServers.map { FallbackServer($0, rateLimiter: rateLimiter) }
        let scheduler = SegmentScheduler(files: job.files, resolved: resolved)
        let remaining = await scheduler.remainingCount
        let workerCount = max(1, min(server.maxConnections, remaining == 0 ? 1 : remaining))

        // 1 Hz progress ticker (also a crude speed gauge: bytes since last tick).
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.emitProgressTick()
            }
        }

        // Authenticate one connection before expanding the pool. A rejected extra socket
        // must not invalidate credentials already accepted by the same server.
        var first: (any DownloadConnection)?
        if remaining > 0 {
            let candidate = makeConnection(server, rateLimiter)
            do {
                try await candidate.open()
                first = candidate
                connectionOpened()
            } catch let error as NNTPError {
                if case .authenticationFailed(let code) = error { recordAuthFailure(code: code) }
                if error == .badGreeting(502) { recordAuthFailure(code: 502) }
                await candidate.close()
            } catch { await candidate.close() }
        }
        let initialConnection = first
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<workerCount {
                group.addTask { [weak self] in
                    await self?.runWorker(
                        server: server, scheduler: scheduler, assembler: assembler, rateLimiter: rateLimiter,
                        fallbacks: fallbacks, initialConnection: index == 0 ? initialConnection : nil)
                }
            }
            await group.waitForAll()
        }
        // A worker rejected during login can return its item after the last healthy
        // worker has drained the queue. Reclaim that work with a single connection.
        if !Task.isCancelled, authFailureReason == nil, await scheduler.remainingCount > 0 {
            await runWorker(
                server: server, scheduler: scheduler, assembler: assembler,
                rateLimiter: rateLimiter, fallbacks: fallbacks, allowsPoolReduction: false)
        }
        ticker.cancel()

        // Finalize any fully-resolved files not already finalized incrementally (e.g. full resume).
        for file in job.files where !finalizedFiles.contains(file.id) {
            if (perFileResolved[file.id] ?? 0) >= file.segments.count {
                await finalizeFile(file.id)
            }
        }
        await assembler.closeAll()

        await checkpointStore.flush(
            Checkpoint(
                jobID: job.id, completedSegmentIDs: completed, missingSegmentIDs: missing,
                finalizedFilenames: finalizedNames, decodedSizes: decodedSizes))

        // Terminal outcome, in priority order. Auth/permission failures are configuration errors;
        // transient exhaustion means the link gave out — both are retryable and must NOT be
        // reported as a completed (holed) download.
        if let reason = storageFailureReason ?? authFailureReason {
            emit(.finished(.failed(reason: reason)))
        } else if Task.isCancelled {
            emit(.finished(.cancelled))
        } else if !transientlyFailed.isEmpty {
            emit(
                .finished(
                    .failed(
                        reason:
                            "The connection dropped before the download finished. Retry to pick up where it left off."
                    )))
        } else {
            emit(.finished(.completed(downloadedBytes: downloadedBytes, missingSegments: missing.count)))
        }
    }

    // nonisolated: owns its connection as plain sequential local state and hops to the actor
    // only for shared accounting — avoids cross-isolation captures of the mutable connection.
    private nonisolated func runWorker(
        server: ServerConfig, scheduler: SegmentScheduler, assembler: FileAssembler,
        rateLimiter: RateLimiter?, fallbacks: [FallbackServer],
        initialConnection: (any DownloadConnection)? = nil, allowsPoolReduction: Bool = true
    ) async {
        var connection = initialConnection
        let maxAttempts = Self.maxAttemptsPerSegment

        workLoop: while !Task.isCancelled {
            guard let item = await scheduler.next() else { break }
            var attempts = 0

            attemptLoop: while true {
                if Task.isCancelled { break workLoop }  // cancellation never records an outcome
                attempts += 1

                if connection == nil {
                    let candidate = makeConnection(server, rateLimiter)
                    do {
                        try await candidate.open()
                        connection = candidate
                        await connectionOpened()
                    } catch let error as NNTPError {
                        await candidate.close()
                        if allowsPoolReduction,
                            await retireRejectedConnection(error, item: item, scheduler: scheduler)
                        {
                            return
                        }
                        if case .authenticationFailed(let code) = error {
                            await recordAuthFailure(code: code); return
                        }
                        if case .cancelled = error { break workLoop }
                        // Transient connect failure (unreachable/refused/timeout): retry, then hand
                        // the segment back for a later attempt rather than losing it.
                        if attempts >= maxAttempts {
                            await giveUpTransiently(item, scheduler: scheduler); break attemptLoop
                        }
                        try? await Task.sleep(for: backoff(attempts)); continue
                    } catch {
                        if attempts >= maxAttempts {
                            await giveUpTransiently(item, scheduler: scheduler); break attemptLoop
                        }
                        try? await Task.sleep(for: backoff(attempts)); continue
                    }
                }
                guard let conn = connection else { continue }

                do {
                    let lines: [Data]
                    do {
                        lines = try await fetchWithTimeout(conn, messageID: item.segment.messageID)
                    } catch NNTPError.articleUnavailable {
                        guard !fallbacks.isEmpty else { throw NNTPError.articleUnavailable(code: 430) }
                        await conn.close(); await connectionClosed(); connection = nil
                        var replacement: [Data]?
                        for fallback in fallbacks {
                            try Task.checkCancellation()
                            if let result = try? await fallback.article(item.segment.messageID) {
                                replacement = result; break
                            }
                        }
                        try Task.checkCancellation()
                        guard let replacement else { throw NNTPError.articleUnavailable(code: 430) }
                        lines = replacement
                    }
                    let segment = try YEncDecoder.decode(bodyLines: lines)
                    guard let size = segment.header.size, size > 0,
                        segment.fileOffset <= size, segment.data.count <= size - segment.fileOffset,
                        segment.declaredPartSize.map({ $0 == segment.data.count }) ?? false,
                        segment.header.part.map({ $0 == item.segment.number }) ?? true,
                        item.totalSegments == 1 || segment.header.isMultipart
                    else { throw YEncError.emptyBody }

                    if segment.crcMatches == false {
                        // The article's bytes are corrupt on the server — retrying the same
                        // article won't help; after exhausting attempts treat it as missing so
                        // PAR2 can repair it. Corruption is not a transient network condition.
                        await conn.close(); await connectionClosed(); connection = nil
                        if attempts >= maxAttempts {
                            await markMissing(item, reason: "CRC mismatch"); break attemptLoop
                        }
                        try? await Task.sleep(for: backoff(attempts)); continue
                    }

                    try await rememberHeader(fileID: item.fileID, size: size, name: segment.header.name)
                    try await assembler.write(
                        fileID: item.fileID, data: segment.data,
                        at: segment.fileOffset, declaredFileSize: segment.header.size,
                        declaredName: segment.header.name)
                    await markCompleted(item, bytes: segment.data.count)
                    break attemptLoop
                } catch let error as NNTPError {
                    if case .articleUnavailable = error {
                        // Genuinely, permanently gone. Connection is still healthy — keep it.
                        await markMissing(item, reason: "article unavailable"); break attemptLoop
                    }
                    if case .authenticationFailed(let code) = error {
                        await conn.close(); await connectionClosed(); connection = nil
                        await recordAuthFailure(code: code); return
                    }
                    // Transient network error — drop the (possibly half-open) connection and retry.
                    await conn.close(); await connectionClosed(); connection = nil
                    if Task.isCancelled { break workLoop }
                    if attempts >= maxAttempts {
                        await giveUpTransiently(item, scheduler: scheduler); break attemptLoop
                    }
                    try? await Task.sleep(for: backoff(attempts)); continue
                } catch is YEncError {
                    // Malformed article body — like corruption, PAR2 territory after retries.
                    await conn.close(); await connectionClosed(); connection = nil
                    if attempts >= maxAttempts {
                        await markMissing(item, reason: "decode error"); break attemptLoop
                    }
                    try? await Task.sleep(for: backoff(attempts)); continue
                } catch {
                    // Local disk (or unknown) error — do NOT silently hole the file; treat it as a
                    // retryable failure.
                    await conn.close(); await connectionClosed(); connection = nil
                    if Task.isCancelled { break workLoop }
                    if attempts >= maxAttempts {
                        await giveUpTransiently(item, scheduler: scheduler); break attemptLoop
                    }
                    try? await Task.sleep(for: backoff(attempts)); continue
                }
            }
        }

        if let connection {
            await connection.close()
            await connectionClosed()
        }
    }

    // MARK: - Result accounting (actor-isolated)

    private func rememberHeader(fileID: String, size: Int, name: String?) throws {
        if let previous = decodedSizes[fileID], previous != size { throw YEncError.emptyBody }
        decodedSizes[fileID] = size
        if let name, !name.isEmpty { finalizedNames[fileID] = FileAssembler.sanitized(name) }
    }
    private func markCompleted(_ item: SegmentScheduler.WorkItem, bytes: Int) async {
        guard !completed.contains(item.segment.id) else { return }
        completed.insert(item.segment.id)
        transientlyFailed.remove(item.segment.id)  // a requeued segment that finally succeeded
        downloadedBytes += bytes
        perFileResolved[item.fileID, default: 0] += 1
        emit?(.segmentCompleted(fileID: item.fileID, segmentID: item.segment.id, decodedBytes: bytes))
        await scheduleCheckpoint()
        await maybeFinalize(item.fileID)
    }

    private func markMissing(_ item: SegmentScheduler.WorkItem, reason: String) async {
        guard !missing.contains(item.segment.id) else { return }
        missing.insert(item.segment.id)
        perFileResolved[item.fileID, default: 0] += 1
        perFileMissing[item.fileID, default: 0] += 1
        emit?(.segmentMissing(fileID: item.fileID, segmentID: item.segment.id, reason: reason))
        await scheduleCheckpoint()
        await maybeFinalize(item.fileID)
    }

    /// Transient exhaustion: try to hand the segment back to the queue; if it has been requeued too
    /// many times, record it as a (non-persisted) transient failure so the run ends as retryable.
    private func giveUpTransiently(_ item: SegmentScheduler.WorkItem, scheduler: SegmentScheduler) async {
        if await scheduler.requeue(item) { return }
        transientlyFailed.insert(item.segment.id)
    }

    private func retireRejectedConnection(
        _ error: NNTPError, item: SegmentScheduler.WorkItem, scheduler: SegmentScheduler
    ) async -> Bool {
        guard authenticated,
            error == .authenticationFailed(502) || error == .badGreeting(502)
        else { return false }
        await giveUpTransiently(item, scheduler: scheduler)
        return true
    }

    private func recordAuthFailure(code: Int) {
        guard authFailureReason == nil else { return }
        authFailureReason =
            code == 502
            ? "The provider refused access (502). Check your connection limit, active sessions and account access, then retry."
            : "The server rejected the login (code \(code)). Check the username and password in Settings."
        currentTask?.cancel()  // stop the whole job — a per-segment retry can't fix a login error
    }

    private func maybeFinalize(_ fileID: String) async {
        guard let total = perFileTotal[fileID],
            (perFileResolved[fileID] ?? 0) >= total,
            !finalizedFiles.contains(fileID)
        else { return }
        await finalizeFile(fileID)
    }

    private func finalizeFile(_ fileID: String) async {
        guard let assembler, !finalizedFiles.contains(fileID) else { return }
        do {
            guard let url = try await assembler.finalize(fileID: fileID) else { throw YEncError.emptyBody }
            finalizedFiles.insert(fileID)
            finalizedNames[fileID] = url.lastPathComponent
            emit?(.fileCompleted(fileID: fileID, url: url, missingSegments: perFileMissing[fileID] ?? 0))
        } catch {
            storageFailureReason = "The downloaded file could not be saved. Free storage and resume."
        }
    }

    private func connectionOpened() { activeConnections += 1; authenticated = true }
    private func connectionClosed() { activeConnections = max(0, activeConnections - 1) }

    private func emitProgressTick() {
        let delta = max(0, downloadedBytes - bytesAtLastTick)
        bytesAtLastTick = downloadedBytes
        // Exponential moving average so the reported speed (and the Live Activity ETA it feeds)
        // doesn't lurch with per-second noise on a mobile link.
        let alpha = 0.4
        smoothedBytesPerSecond =
            smoothedBytesPerSecond == 0
            ? Double(delta)
            : alpha * Double(delta) + (1 - alpha) * smoothedBytesPerSecond
        emit?(
            .progress(
                downloadedBytes: downloadedBytes,
                bytesPerSecond: Int(smoothedBytesPerSecond.rounded()),
                activeConnections: activeConnections))
    }

    private func scheduleCheckpoint() async {
        guard let checkpointStore else { return }
        let cp = Checkpoint(
            jobID: jobID, completedSegmentIDs: completed, missingSegmentIDs: missing,
            finalizedFilenames: finalizedNames, decodedSizes: decodedSizes)
        await checkpointStore.scheduleSave(cp)
    }

    private func resetState() {
        emit = nil; jobID = ""; workingDir = nil; assembler = nil; checkpointStore = nil
        filesByID = [:]
        downloadedBytes = 0; bytesAtLastTick = 0; smoothedBytesPerSecond = 0; activeConnections = 0;
        authenticated = false
        completed = []; missing = []; transientlyFailed = []; authFailureReason = nil
        perFileTotal = [:]; perFileResolved = [:]; perFileMissing = [:]; finalizedFiles = []
        finalizedNames = [:]; storageFailureReason = nil; decodedSizes = [:]
    }

    // MARK: - Helpers

    /// Race a body fetch against a stall timeout. Only the timeout path closes the connection (to
    /// unblock the suspended read); other errors are rethrown with the connection intact so a
    /// healthy "article unavailable" response doesn't needlessly tear down a reusable connection.
    private nonisolated func fetchWithTimeout(_ conn: any DownloadConnection, messageID: String) async throws
        -> [Data]
    {
        let timeout = Self.fetchTimeout
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [Data].self) { group in
                group.addTask { try await conn.fetchBody(messageID: messageID) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    await conn.close()
                    throw NNTPError.timeout
                }
                defer { group.cancelAll() }
                return try await group.next() ?? []
            }
        } onCancel: {
            Task { await conn.close() }
        }
    }

    /// Exponential backoff with jitter, capped at ~8s.
    private nonisolated func backoff(_ attempt: Int) -> Duration {
        let base = min(8.0, 0.25 * pow(2.0, Double(attempt - 1)))
        let jitter = Double.random(in: 0...0.4)
        return .milliseconds(Int((base + jitter) * 1000))
    }
}
