import Foundation

/// Writes an independently verified video to a temporary file. The caller owns the result.
public enum UsenetFileDownload {
    public static func write(
        video: UsenetVideo, session: UsenetSession, to destination: URL, connections: Int = 1,
        progress: @Sendable (Int64, Int64) async -> Void = { _, _ in }
    ) async throws {
        guard destination.isFileURL, video.length > 0,
            !FileManager.default.fileExists(atPath: destination.path)
        else { throw UsenetError.storage }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw UsenetError.storage
        }
        do {
            try await withTaskCancellationHandler {
                try await copy(
                    video: video, session: session, to: destination, connections: connections,
                    progress: progress)
            } onCancel: {
                Task { await session.stop() }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func copy(
        video: UsenetVideo, session: UsenetSession, to destination: URL, connections: Int,
        progress: @Sendable (Int64, Int64) async -> Void
    ) async throws {
        let handle = try FileHandle(forWritingTo: destination)
        do {
            let blockSize = 1024 * 1024
            let workers = max(1, min(connections, UsenetProvider.connectionRange.upperBound))
            try await withThrowingTaskGroup(of: (Int64, Data).self) { group in
                var scheduled: Int64 = 0, written: Int64 = 0
                var lastProgress: TimeInterval = 0
                var completed: [Int64: Data] = [:]
                func schedule() {
                    guard scheduled < video.length else { return }
                    let offset = scheduled
                    let count = Int(min(Int64(blockSize), video.length - offset))
                    scheduled += Int64(count)
                    group.addTask {
                        let data = try await session.read(
                            video: video, offset: offset, count: count, priority: .download)
                        guard data.count == count else { throw UsenetError.missingArticle }
                        return (offset, data)
                    }
                }
                for _ in 0..<workers { schedule() }
                while let (offset, bytes) = try await group.next() {
                    completed[offset] = bytes
                    while let next = completed.removeValue(forKey: written) {
                        try Task.checkCancellation()
                        try handle.write(contentsOf: next)
                        written += Int64(next.count)
                        let now = ProcessInfo.processInfo.systemUptime
                        if lastProgress == 0 || now - lastProgress >= 0.5 || written == video.length {
                            lastProgress = now
                            await progress(written, video.length)
                        }
                        schedule()
                    }
                }
                guard written == video.length else { throw UsenetError.missingArticle }
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }
}
