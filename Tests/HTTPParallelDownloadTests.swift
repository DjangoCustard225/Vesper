import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VesperCore

enum DownloadFiles {
    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    static func prefix(_ url: URL) throws -> Data {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        return try input.read(upToCount: 4096) ?? Data()
    }
    static func protect(_ url: URL) throws {}
}

@main struct HTTPRegression {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let size = HTTPDownloadPolicy.minimumParallelSize + 123
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func transfer(_ path: String) -> HTTPParallelDownload {
            let source = URL(string: base + path)!
            return HTTPParallelDownload(
                root: root.appendingPathComponent(path), source: source,
                identity: HTTPRangeIdentity(
                    sourceURL: source.absoluteString, etag: "\"version1\"", total: size)!,
                cellular: true, report: { _, _ in })
        }
        for path in ["/valid", "/resume"] {
            let output = root.appendingPathComponent(path + ".mkv")
            if path == "/resume" {
                do {
                    _ = try await transfer(path).run(destination: output)
                    preconditionFailure("Interrupted transfer must fail")
                } catch HTTPDownloadError.status(let code, let after) {
                    precondition(code == 503 && after == "15")
                }
                precondition(!FileManager.default.fileExists(atPath: output.path))
            }
            let receipt = try await transfer(path).run(destination: output)
            precondition(receipt.total == size && DownloadFiles.size(output) == size)
            let data = try Data(contentsOf: output)
            let pattern: [UInt8] = [0x1a, 0x45, 0xdf, 0xa3]
            precondition(data.enumerated().allSatisfy { $0.element == pattern[$0.offset % 4] })
        }
        let cancelledOutput = root.appendingPathComponent("cancelled.mkv")
        let cancelled = Task { try await transfer("/cancel").run(destination: cancelledOutput) }
        try await Task.sleep(for: .milliseconds(100))
        cancelled.cancel()
        do {
            _ = try await cancelled.value; preconditionFailure("Cancellation must finish without assembly")
        } catch is CancellationError {}
        precondition(!FileManager.default.fileExists(atPath: cancelledOutput.path))
        for path in ["/ignored", "/wrong-range", "/changed", "/short"] {
            let output = root.appendingPathComponent(path + ".mkv")
            do {
                _ = try await transfer(path).run(destination: output)
                preconditionFailure("Invalid response must not assemble")
            } catch is HTTPDownloadError {
                precondition(!FileManager.default.fileExists(atPath: output.path))
            } catch let error as URLError {
                precondition(path == "/short" && error.code != .cancelled)
            }
        }
        print("HTTP range transfers passed assembly, persisted resume and four invalid-response checks.")
    }
}
