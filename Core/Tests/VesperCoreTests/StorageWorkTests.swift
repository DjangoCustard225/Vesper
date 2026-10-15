import XCTest
@testable import VesperCore

final class StorageWorkTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func event(_ attempt: Int) -> DiagnosticEvent {
        DiagnosticEvent(
            date: Date(), operation: .catalog, attempt: attempt, milliseconds: 1, status: 200,
            outcome: .success)
    }

    func testDiagnosticsPersistAtBatchBoundaryAndFlushLatestTail() async throws {
        let directory = directory(), file = directory.appendingPathComponent("requests.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(directory: directory, flushInterval: .seconds(60))
        for index in 0..<19 { await recorder.record(event(index)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await recorder.record(event(19))
        var saved = try JSONDecoder().decode([DiagnosticEvent].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.count, 20)
        await recorder.record(event(20))
        saved = try JSONDecoder().decode([DiagnosticEvent].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.count, 20)
        await recorder.flush()
        let restarted = DiagnosticRecorder(directory: directory)
        let data = try await restarted.export()
        saved = try JSONDecoder().decode([DiagnosticEvent].self, from: data)
        XCTAssertEqual(saved.count, 21)
        XCTAssertEqual(saved.last?.attempt, 20)
    }

    func testDiagnosticsTimerPersistsSmallBatch() async throws {
        let directory = directory(), file = directory.appendingPathComponent("requests.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(directory: directory, flushInterval: .milliseconds(20))
        await recorder.record(event(1))
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let saved = try JSONDecoder().decode([DiagnosticEvent].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved.count, 1)
    }

    func testDiagnosticsExportFlushesWithoutWaitingForTimer() async throws {
        let directory = directory(), file = directory.appendingPathComponent("requests.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DiagnosticRecorder(directory: directory, flushInterval: .seconds(60))
        await recorder.record(event(1))
        let exported = try await recorder.export()
        let saved = try Data(contentsOf: file)
        XCTAssertEqual(
            try JSONDecoder().decode([DiagnosticEvent].self, from: exported).count,
            try JSONDecoder().decode([DiagnosticEvent].self, from: saved).count)
    }

    func testCacheReplacementAndRemovalMaintainByteAccounting() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory, byteLimit: 600)
        await cache.save(String(repeating: "a", count: 180), key: "one")
        await cache.save("small", key: "one")
        await cache.save(String(repeating: "b", count: 180), key: "two")
        let first = await cache.value(String.self, key: "one", ttl: 60)
        let second = await cache.value(String.self, key: "two", ttl: 60)
        XCTAssertEqual(first?.value, "small")
        XCTAssertNotNil(second)
        let expiredDate = Date().addingTimeInterval(-8 * 24 * 3600)
        await cache.save("expired", key: "expired", now: expiredDate)
        let expired = await cache.value(String.self, key: "expired", ttl: 60)
        XCTAssertNil(expired)
        await cache.save("small", key: "three")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let size = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(size, 600)
    }

    func testRestartIndexesExistingFilesAndEvictsOldest() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory)
        await cache.save(String(repeating: "a", count: 180), key: "old")
        let oldFile = directory.appendingPathComponent(ResponseCache.fingerprint("old") + ".json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oldFile.path)
        let restarted = ResponseCache(directory: directory, byteLimit: 600)
        await restarted.save(String(repeating: "b", count: 180), key: "new")
        let old = await restarted.value(String.self, key: "old", ttl: 60)
        let new = await restarted.value(String.self, key: "new", ttl: 60)
        XCTAssertNil(old)
        XCTAssertNotNil(new)
    }

    func testClearResetsIndexAndRejectsOldGenerationWrites() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ResponseCache(directory: directory, byteLimit: 600)
        await cache.save("old", key: "old")
        let token = await cache.token()
        await cache.clear()
        await cache.save("late", key: "late", token: token)
        await cache.save(String(repeating: "n", count: 180), key: "new")
        let late = await cache.value(String.self, key: "late", ttl: 60)
        let new = await cache.value(String.self, key: "new", ttl: 60)
        XCTAssertNil(late)
        XCTAssertNotNil(new)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
    }
}
