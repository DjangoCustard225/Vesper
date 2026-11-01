import Foundation
import Testing
@testable import DownloadEngine

@Test func finalizedAuthoritativeNameSurvivesResume() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = Data("complete-video".utf8)
    let output = root.appendingPathComponent("actual-video.mkv")
    try bytes.write(to: output)
    let store = CheckpointStore(directory: root, jobID: "job")
    await store.flush(
        Checkpoint(
            jobID: "job", completedSegmentIDs: ["f:1"], finalizedFilenames: ["f": "actual-video.mkv"],
            decodedSizes: ["f": bytes.count]))
    let file = FileSpec(
        id: "f", filename: "obfuscated-name", groups: [],
        segments: [SegmentSpec(id: "f:1", messageID: "segment@example", byteCount: bytes.count, number: 1)])
    let engine = NZBDownloadEngine()
    var result: EngineResult?
    for await event in await engine.run(
        job: JobSpec(id: "job", files: [file], workingDirectory: root),
        server: ServerConfig(
            host: "unused", port: 563, useSSL: true, username: nil, password: nil, maxConnections: 1))
    {
        if case .finished(let outcome) = event { result = outcome }
    }
    #expect(result == .completed(downloadedBytes: bytes.count, missingSegments: 0))
    #expect(try Data(contentsOf: output) == bytes)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("obfuscated-name").path))
}

@Test func resumedSparseFileUsesDecodedLengthInsteadOfEncodedPadding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = FileAssembler(directory: root)
    _ = try await first.prepare(fileID: "f", filename: "video.mkv", totalBytes: 100)
    try await first.write(fileID: "f", data: Data("video".utf8), at: 0, declaredFileSize: 5)
    await first.closeAll()
    let resumed = FileAssembler(directory: root)
    _ = try await resumed.prepare(fileID: "f", filename: "video.mkv", totalBytes: 100, decodedSize: 5)
    let url = try #require(await resumed.finalize(fileID: "f"))
    #expect(try Data(contentsOf: url) == Data("video".utf8))
}

@Test func oldCheckpointDecodesWithoutNewFields() throws {
    let checkpoint = try JSONDecoder().decode(
        Checkpoint.self,
        from: Data(#"{"jobID":"job","completedSegmentIDs":["1"],"missingSegmentIDs":[]}"#.utf8))
    #expect(checkpoint.completedSegmentIDs == ["1"])
    #expect(checkpoint.finalizedFilenames.isEmpty)
    #expect(checkpoint.decodedSizes.isEmpty)
}

@Test func fullyDownloadedPartFinalizesAtItsPersistedDecodedSize() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let assembler = FileAssembler(directory: root)
    _ = try await assembler.prepare(fileID: "f", filename: "video.mkv", totalBytes: 100)
    try await assembler.write(fileID: "f", data: Data("video".utf8), at: 0, declaredFileSize: 5)
    await assembler.closeAll()
    let checkpoint = CheckpointStore(directory: root, jobID: "job")
    await checkpoint.flush(Checkpoint(jobID: "job", completedSegmentIDs: ["f:1"], decodedSizes: ["f": 5]))
    let engine = NZBDownloadEngine()
    let file = FileSpec(
        id: "f", filename: "video.mkv", groups: [],
        segments: [SegmentSpec(id: "f:1", messageID: "unused@example", byteCount: 100, number: 1)])
    var result: EngineResult?
    for await event in await engine.run(
        job: JobSpec(id: "job", files: [file], workingDirectory: root),
        server: ServerConfig(
            host: "unused", port: 563, useSSL: true, username: nil, password: nil, maxConnections: 1))
    {
        if case .finished(let outcome) = event { result = outcome }
    }
    #expect(result == .completed(downloadedBytes: 100, missingSegments: 0))
    #expect(try Data(contentsOf: root.appendingPathComponent("video.mkv")) == Data("video".utf8))
}

@Test func checkpointReplacementKeepsTheLatestCompletedSegments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CheckpointStore(directory: root, jobID: "job")
    await store.flush(Checkpoint(jobID: "job", completedSegmentIDs: ["1"]))
    await store.flush(Checkpoint(jobID: "job", completedSegmentIDs: ["1", "2"]))
    let restored = await store.load()
    #expect(restored?.completedSegmentIDs == ["1", "2"])
}
