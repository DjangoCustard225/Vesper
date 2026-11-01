import Foundation
import XCTest
@testable import UsenetEngine

/// A socket that can remain silent until close, exercising the same continuation contract as Network.framework.
final class ScriptedWire: NNTPWire, @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data]
    private var pending: CheckedContinuation<Data, Error>?
    private var closed = false
    private var commands: [String] = []
    init(_ chunks: [String] = []) { self.chunks = chunks.map { Data($0.utf8) } }
    func connect() async throws {}
    func send(_ data: Data) async throws { record(data) }
    private func record(_ data: Data) {
        lock.lock(); defer { lock.unlock() }; commands.append(String(decoding: data, as: UTF8.self))
    }
    func sent() -> [String] { lock.lock(); defer { lock.unlock() }; return commands }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock(); continuation.resume(throwing: UsenetError.connection)
            } else if !chunks.isEmpty {
                let data = chunks.removeFirst(); lock.unlock(); continuation.resume(returning: data)
            } else {
                pending = continuation; lock.unlock()
            }
        }
    }
    func feed(_ value: String) {
        lock.lock()
        if let continuation = pending {
            pending = nil; lock.unlock(); continuation.resume(returning: Data(value.utf8))
        } else {
            chunks.append(Data(value.utf8)); lock.unlock()
        }
    }
    func close() {
        lock.lock(); closed = true; let continuation = pending; pending = nil; lock.unlock()
        continuation?.resume(throwing: UsenetError.connection)
    }
}

final class TransportTests: XCTestCase {
    func testAuthenticationBodyDotUnstuffingAndConnectionReuse() async throws {
        let wire = ScriptedWire([
            "200 ready\r\n", "381 password\r\n", "281 accepted\r\n", "222 body\r\n..first\r\nsecond\r\n.\r\n",
            "222 body\r\nthird\r\n.\r\n",
        ])
        let client = NNTPClient(provider: provider, wire: wire, deadline: .seconds(1))
        let first = try await client.article("one@example"), second = try await client.article("two@example")
        XCTAssertEqual(first, [Data(".first".utf8), Data("second".utf8)]);
        XCTAssertEqual(second, [Data("third".utf8)])
        XCTAssertEqual(
            wire.sent(),
            [
                "AUTHINFO USER user\r\n", "AUTHINFO PASS secret\r\n", "BODY <one@example>\r\n",
                "BODY <two@example>\r\n",
            ])
        await client.close()
    }
    func testSilentGreetingAuthenticationAndBodyAllRespectDeadline() async throws {
        for replies in [
            [], ["200 ready\r\n"], ["200 ready\r\n", "381 password\r\n"],
            ["200 ready\r\n", "281 accepted\r\n", "222 body\r\npartial\r\n"],
        ] {
            let wire = ScriptedWire(replies),
                client = NNTPClient(provider: provider, wire: wire, deadline: .milliseconds(40))
            let clock = ContinuousClock(), start = clock.now
            do { _ = try await client.article("one@example"); XCTFail("Silent socket succeeded") } catch {
                XCTAssertTrue(error is UsenetError)
            }
            XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        }
    }
    func testCancellationClosesSilentSocketBeforeJoining() async throws {
        let wire = ScriptedWire(), client = NNTPClient(provider: provider, wire: wire, deadline: .seconds(30))
        let operation = Task { try await client.article("one@example") }
        try await Task.sleep(for: .milliseconds(10)); let clock = ContinuousClock(), start = clock.now
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled socket succeeded") } catch {}
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
    }
    func testPoolPromotesPlaybackAheadOfQueuedPrefetchAndCancelsWaiters() async throws {
        let wire = ScriptedWire(["200 ready\r\n", "281 accepted\r\n"])
        let pool = try NNTPPool(provider: provider) {
            NNTPClient(provider: provider, wire: wire, deadline: .seconds(2))
        }
        let first = Task { try await pool.article("first@example", priority: .playback) }
        while !wire.sent().contains("BODY <first@example>\r\n") {
            try await Task.sleep(for: .milliseconds(1))
        }
        let speculative = Task { try await pool.article("prefetch@example", priority: .prefetch) }
        try await Task.sleep(for: .milliseconds(10))
        let visible = Task { try await pool.article("visible@example", priority: .playback) }
        try await Task.sleep(for: .milliseconds(10))
        wire.feed("222 body\r\none\r\n.\r\n"); _ = try await first.value
        while !wire.sent().contains("BODY <visible@example>\r\n") {
            try await Task.sleep(for: .milliseconds(1))
        }
        speculative.cancel()
        wire.feed("222 body\r\ntwo\r\n.\r\n"); _ = try await visible.value
        do { _ = try await speculative.value; XCTFail("Cancelled waiter succeeded") } catch {}
        XCTAssertFalse(wire.sent().contains("BODY <prefetch@example>\r\n"))
        await pool.stop()
    }
    func testMissingArticleAndAuthenticationHaveSafeErrors() async throws {
        for (replies, expected) in [
            (["200 ready\r\n", "481 wrong secret token\r\n"], UsenetError.authentication),
            (["200 ready\r\n", "281 ok\r\n", "430 private article id\r\n"], .missingArticle),
        ] {
            let client = NNTPClient(provider: provider, wire: ScriptedWire(replies))
            await expectError(expected) { _ = try await client.article("private@example") }
            XCTAssertFalse(expected.localizedDescription.contains("secret"));
            XCTAssertFalse(expected.localizedDescription.contains("private@example"))
        }
    }
}
