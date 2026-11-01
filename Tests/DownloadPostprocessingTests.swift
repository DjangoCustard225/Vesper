import Foundation
import VesperCore

enum DownloadFiles {
    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
enum UsenetDownloadTransfer {
    // ACTUAL_COPY
}
@main struct PostprocessingRegression {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), output = root.appendingPathComponent("partial")
        let bytes = Data(repeating: 0x45, count: 8 * 1024 * 1024)
        try bytes.write(to: source)
        let reporter = DownloadWorkReporter { _ in }
        try UsenetDownloadTransfer.copy(source, to: output, reporting: reporter)
        let copied = try Data(contentsOf: output)
        precondition(copied == bytes)
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try UsenetDownloadTransfer.copy(source, to: output, reporting: reporter)
        }
        do {
            try await cancelled.value; preconditionFailure("Cancelled copies must throw")
        } catch is CancellationError {}
        precondition(!FileManager.default.fileExists(atPath: output.path))
        var matrix: [UInt16] = [1, 1, 1, 2]
        var rhs = [[UInt16](repeating: 3, count: 32768), [UInt16](repeating: 4, count: 32768)]
        var checkpoints = 0
        do {
            _ = try ReedSolomon.solve(matrix: &matrix, rhs: &rhs, m: 2) { _ in
                checkpoints += 1
                if checkpoints == 4 { throw CancellationError() }
            }
            preconditionFailure("Repair cancellation must interrupt word operations")
        } catch is CancellationError {}
        precondition(checkpoints == 4)
        matrix = [1, 0, 0, 1]
        rhs = [[1, 2], [3, 4]]
        precondition(ReedSolomon.solve(matrix: &matrix, rhs: &rhs, m: 2))
        precondition(rhs == [[1, 2], [3, 4]])
        print("Passed cancellable video staging and repair algebra checks.")
    }
}
