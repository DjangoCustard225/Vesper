import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VesperCore

private final class HTTPRangeProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void
    private var last: TimeInterval = 0
    private let lock = NSLock()
    private var rejection: HTTPDownloadError?
    private let identity: HTTPRangeIdentity
    private let range: Range<Int64>
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var staged: (URL, URLResponse)?
    private var stagingError: Error?
    private let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    func download(session: URLSession, request: URLRequest) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true
            let task = self.task; self.lock.unlock(); task?.cancel()
        }
    }
    init(identity: HTTPRangeIdentity, range: Range<Int64>, report: @escaping @Sendable (Int64) -> Void) {
        self.identity = identity; self.range = range; self.report = report
    }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        lock.lock(); defer { lock.unlock() }
        guard rejection == nil, !cancelled else { return }
        do {
            guard let response = downloadTask.response else { throw DownloadFailure.response }
            try FileManager.default.moveItem(at: location, to: self.location)
            staged = (self.location, response)
        } catch { stagingError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil; self.task = nil
        let failure: Error? = cancelled ? CancellationError() : (rejection ?? error ?? stagingError)
        let staged = self.staged; self.staged = nil
        lock.unlock()
        if let failure {
            try? FileManager.default.removeItem(at: location)
            continuation?.resume(throwing: failure)
        } else if let staged {
            continuation?.resume(returning: staged)
        } else {
            continuation?.resume(throwing: DownloadFailure.response)
        }
    }
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard rejection == nil else { return }
        if let response = downloadTask.response as? HTTPURLResponse {
            if response.statusCode != 206 {
                rejection =
                    response.statusCode == 200
                    ? .invalidRange
                    : .status(response.statusCode, response.value(forHTTPHeaderField: "Retry-After"))
            } else if let actual = HTTPContentRange(response.value(forHTTPHeaderField: "Content-Range")),
                actual.lower == range.lowerBound, actual.upper == range.upperBound - 1,
                actual.total == identity.total,
                HTTPDownloadPolicy.isIdentityEncoding(response.value(forHTTPHeaderField: "Content-Encoding"))
            {
                if HTTPDownloadPolicy.strongETag(response.value(forHTTPHeaderField: "ETag")) != identity.etag
                {
                    rejection = .changed
                }
            } else {
                rejection = .invalidRange
            }
            if rejection != nil { downloadTask.cancel(); return }
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - last >= 1 else { return }
        last = now; report(totalBytesWritten)
    }
}

/// In-process acceleration keeps complete, identity-checked ranges across interruptions.
actor HTTPParallelDownload {
    private struct Journal: Codable {
        let identity: HTTPRangeIdentity
        var completed: Set<Int>
    }
    private let root: URL
    private let identity: HTTPRangeIdentity
    private let source: URL
    private let cellular: Bool
    private let report: @Sendable (Int64, Int64) async -> Void
    private let finishing: @Sendable (DownloadWorkProgress) async -> Void
    private var completed: Set<Int> = []
    private var inFlight: [Int: Int64] = [:]
    private var lastProgress: TimeInterval = 0
    private let ranges: [Range<Int64>]
    private var journalURL: URL { root.appendingPathComponent("ranges.json") }
    private func part(_ index: Int) -> URL { root.appendingPathComponent("\(index).part") }

    init(
        root: URL, source: URL, identity: HTTPRangeIdentity, cellular: Bool,
        report: @escaping @Sendable (Int64, Int64) async -> Void,
        finishing: @escaping @Sendable (DownloadWorkProgress) async -> Void = { _ in }
    ) {
        self.root = root; self.source = source; self.identity = identity; self.report = report
        self.finishing = finishing
        self.cellular = cellular
        ranges = HTTPDownloadPolicy.ranges(total: identity.total)
    }

    func run(destination: URL) async throws -> DownloadReceipt {
        let saved = try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        if let saved, saved.identity == identity {
            completed = saved.completed
        } else {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try DownloadFiles.protect(root)
        let ranges = ranges
        completed = Set(
            completed.filter { index in
                ranges.indices.contains(index) && DownloadFiles.size(part(index)) == ranges[index].count
            })
        let pending = ranges.indices.filter { !completed.contains($0) }
        await emitProgress(force: true)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var work = pending.makeIterator()
            for _ in 0..<4 {
                if let index = work.next() { group.addTask { try await self.fetch(index) } }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if let index = work.next() { group.addTask { try await self.fetch(index) } }
            }
        }
        try Task.checkCancellation()
        guard completed.count == ranges.count else { throw DownloadFailure.incomplete }
        let assembled = root.appendingPathComponent("assembled.partial")
        try? FileManager.default.removeItem(at: assembled)
        guard FileManager.default.createFile(atPath: assembled.path, contents: nil) else {
            throw DownloadFailure.storage
        }
        let output = try FileHandle(forWritingTo: assembled)
        var written: Int64 = 0
        var lastAssemblyUpdate = ProcessInfo.processInfo.systemUptime
        await finishing(DownloadWorkProgress(.assembling))
        do {
            for index in ranges.indices {
                let input = try FileHandle(forReadingFrom: part(index))
                do {
                    while true {
                        try Task.checkCancellation()
                        let bytes = try DownloadFileIO.copyChunk(from: input, to: output)
                        guard bytes > 0 else { break }
                        written += bytes
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastAssemblyUpdate >= 1 {
                            lastAssemblyUpdate = now
                            await finishing(
                                DownloadWorkProgress(
                                    .assembling, fraction: Double(written) / Double(identity.total)))
                        }
                    }
                    try input.close()
                } catch { try? input.close(); throw error }
            }
            try output.synchronize(); try output.close()
            try Task.checkCancellation()
            await finishing(DownloadWorkProgress(.assembling, fraction: 1))
            guard DownloadFiles.size(assembled) == identity.total else { throw DownloadFailure.incomplete }
            try DownloadPolicy.validate(status: 200, mime: nil, prefix: DownloadFiles.prefix(assembled))
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: assembled, to: destination)
            try DownloadFiles.protect(destination)
            return DownloadReceipt(location: destination, status: 200, mime: nil, total: identity.total)
        } catch { try? output.close(); try? FileManager.default.removeItem(at: assembled); throw error }
    }
    private func fetch(_ index: Int) async throws {
        let range = ranges[index]
        var request = URLRequest(url: source)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue(identity.etag, forHTTPHeaderField: "If-Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let progress = HTTPRangeProgress(identity: identity, range: range) { bytes in
            Task { await self.received(index, bytes: bytes) }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.allowsCellularAccess = cellular
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let session = URLSession(configuration: configuration, delegate: progress, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, rawResponse) = try await progress.download(session: session, request: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let response = rawResponse as? HTTPURLResponse else { throw DownloadFailure.response }
        guard response.statusCode == 206 else {
            if response.statusCode == 200 { throw HTTPDownloadError.invalidRange }
            throw HTTPDownloadError.status(
                response.statusCode, response.value(forHTTPHeaderField: "Retry-After"))
        }
        guard let actual = HTTPContentRange(response.value(forHTTPHeaderField: "Content-Range")),
            actual.lower == range.lowerBound, actual.upper == range.upperBound - 1,
            actual.total == identity.total,
            DownloadFiles.size(temporary) == actual.count,
            response.expectedContentLength < 0 || response.expectedContentLength == actual.count,
            HTTPDownloadPolicy.isIdentityEncoding(response.value(forHTTPHeaderField: "Content-Encoding"))
        else { throw HTTPDownloadError.invalidRange }
        guard HTTPDownloadPolicy.strongETag(response.value(forHTTPHeaderField: "ETag")) == identity.etag
        else { throw HTTPDownloadError.changed }
        if index == 0 {
            try DownloadPolicy.validate(
                status: 206, mime: response.mimeType, prefix: DownloadFiles.prefix(temporary))
        }
        try? FileManager.default.removeItem(at: part(index))
        try FileManager.default.moveItem(at: temporary, to: part(index))
        try DownloadFiles.protect(part(index))
        completed.insert(index); inFlight[index] = nil
        try JSONEncoder().encode(Journal(identity: identity, completed: completed)).write(
            to: journalURL, options: .atomic)
        await emitProgress(force: true)
    }
    private func received(_ index: Int, bytes: Int64) async {
        guard !completed.contains(index) else { return }
        inFlight[index] = min(Int64(ranges[index].count), max(0, bytes))
        await emitProgress(force: false)
    }
    private func emitProgress(force: Bool) async {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastProgress >= 1 else { return }
        lastProgress = now
        let committed = completed.reduce(Int64(0)) { $0 + Int64(ranges[$1].count) }
        await report(min(identity.total, committed + inFlight.values.reduce(0, +)), identity.total)
    }
}
