//
//  NNTPConnection.swift
//  DownloadEngine
//
//  One authenticated NNTP connection over Network.framework (TLS or plain). An actor: each
//  connection is owned by exactly one pool worker, which issues BODY fetches serially.
//
//  Timeouts are handled here (open) and by the caller (fetchBody): while a socket read is
//  suspended, the actor is free to service `close()`, which cancels the socket and unblocks the
//  read with an error.
//

import Foundation
#if canImport(Network)
import Network

actor NNTPConnection {
    private let config: ServerConfig
    private static let queue = DispatchQueue(
        label: "de.valentinlehmann.swiftnzb.nntp", attributes: .concurrent)

    /// Bounds connect + greeting + auth so an unreachable host or a silent server can't hang a
    /// worker (or the "Test Connection" probe) forever.
    private static let openTimeout: Double = 20
    /// Hard cap on a single line so a misbehaving server that never sends a newline can't grow
    /// memory without bound. NNTP status/yEnc lines are short; 4 MB is a very generous ceiling.
    private static let maxLineBytes = 4 * 1024 * 1024

    private var connection: NWConnection?
    private var framer = LineFramer()
    private var lineQueue: [Data] = []
    private var lineCursor = 0
    private(set) var isClosed = false
    /// Shared across the job's connections so the cap throttles aggregate throughput.
    private let rateLimiter: RateLimiter?

    init(config: ServerConfig, rateLimiter: RateLimiter? = nil) {
        self.config = config
        self.rateLimiter = rateLimiter
    }

    // MARK: - Lifecycle

    /// Establish the TCP/TLS connection, read the greeting, and authenticate. Bounded by
    /// `openTimeout`; cancels the socket on any failure so nothing is left half-open.
    func open() async throws {
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [self] in try await performOpen() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(Self.openTimeout))
                        await self.close()
                        throw NNTPError.timeout
                    }
                    defer { group.cancelAll() }
                    do { try await group.next() } catch { close(); throw error }
                }
            } onCancel: {
                Task { await self.close() }
            }
        } catch {
            close()
            throw error
        }
    }

    private func performOpen() async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(exactly: config.port) ?? 0) else {
            throw NNTPError.connectionFailed("invalid port \(config.port)")
        }

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 20
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let params: NWParameters =
            config.useSSL
            ? NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
            : NWParameters(tls: nil, tcp: tcp)

        let connection = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: params)
        self.connection = connection

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(cont)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(.success(()))
                case .failed(let error):
                    once.resume(.failure(NNTPError.connectionFailed(String(describing: error))))
                case .cancelled:
                    once.resume(.failure(NNTPError.cancelled))
                case .waiting(let error):
                    // DNS failure, connection refused, or an unreachable host surface here and
                    // NWConnection would otherwise retry internally forever. We manage our own
                    // retries/backoff, so fail fast instead of hanging.
                    once.resume(.failure(NNTPError.connectionFailed(String(describing: error))))
                default:
                    break
                }
            }
            connection.start(queue: Self.queue)
        }
        // Once connected, demote the handler so later state changes don't try to resume again.
        connection.stateUpdateHandler = { _ in }

        let greeting = try await readStatus()
        guard greeting.code == 200 || greeting.code == 201 else {
            throw NNTPError.badGreeting(greeting.code)
        }

        if let username = config.username, !username.isEmpty {
            try await authenticate(user: username, password: config.password)
        }
    }

    /// Cancel the socket. Safe to call while a `fetchBody` read is in flight — it unblocks it.
    func close() {
        isClosed = true
        connection?.cancel()
        connection = nil
    }

    // MARK: - Commands

    /// Fetch and decode-ready body lines for an article. Returns the dot-unstuffed content lines.
    /// Throws `.articleUnavailable` only for the codes that mean the article is genuinely gone.
    func fetchBody(messageID: String) async throws -> [Data] {
        // The message-ID comes from untrusted NZB XML. A CR/LF (or space/bracket) would let a
        // crafted ID inject a second command onto the wire or desync request/response pairing,
        // so reject anything that isn't a well-formed ID before sending.
        guard Self.isValidMessageID(messageID) else {
            throw NNTPError.articleUnavailable(code: 430)
        }
        try await send("BODY <\(messageID)>")
        let status = try await readStatus()
        switch status.code {
        case 222:
            return try await readBodyLines()
        case 420, 423, 430:
            // No such article / no article with that number — genuinely, permanently missing.
            throw NNTPError.articleUnavailable(code: status.code)
        case 480, 481, 482, 483, 502:
            // Authentication or permission problem — a per-segment retry won't help; surface it
            // so the job fails cleanly instead of silently punching holes.
            throw NNTPError.authenticationFailed(status.code)
        case 400, 500:
            // Service temporarily unavailable / shutting down / internal — transient, retry on a
            // fresh connection.
            throw NNTPError.connectionClosed
        default:
            throw NNTPError.protocolError("unexpected BODY response \(status.code)")
        }
    }

    /// A syntactically safe message-ID: no whitespace/control bytes and no angle brackets (we add
    /// our own), non-empty, and length-bounded.
    static func isValidMessageID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 1000 else { return false }
        for scalar in id.unicodeScalars {
            if scalar.value < 0x21 || scalar.value > 0x7E { return false }  // printable ASCII only
            if scalar == "<" || scalar == ">" { return false }
        }
        return true
    }

    // MARK: - Auth

    private func authenticate(user: String, password: String?) async throws {
        try await send("AUTHINFO USER \(user)")
        let r1 = try await readStatus()
        if r1.code == 281 { return }  // accepted, no password needed
        guard r1.code == 381 else { throw NNTPError.authenticationFailed(r1.code) }
        guard let password else { throw NNTPError.authenticationFailed(r1.code) }
        try await send("AUTHINFO PASS \(password)")
        let r2 = try await readStatus()
        guard r2.code == 281 else { throw NNTPError.authenticationFailed(r2.code) }
    }

    // MARK: - Wire I/O

    private func send(_ command: String) async throws {
        guard let connection else { throw NNTPError.notConnected }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: NNTP.command(command),
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: NNTPError.connectionFailed(String(describing: error)))
                    } else {
                        cont.resume(returning: ())
                    }
                })
        }
    }

    private func readStatus() async throws -> NNTPStatus {
        let line = try await nextLine()
        guard let status = NNTPStatus(line: line) else {
            throw NNTPError.protocolError("malformed status line")
        }
        return status
    }

    private func readBodyLines() async throws -> [Data] {
        var lines: [Data] = []
        while true {
            let raw = try await nextLine()
            switch NNTP.processBodyLine(raw) {
            case .terminator: return lines
            case .content(let content): lines.append(content)
            }
        }
    }

    private func nextLine() async throws -> Data {
        while lineCursor >= lineQueue.count {
            // Reset the buffer between refills so the cursor doesn't retain drained lines.
            lineQueue.removeAll(keepingCapacity: true)
            lineCursor = 0
            let chunk = try await receiveChunk()
            lineQueue.append(contentsOf: framer.append(chunk))
            if framer.pendingCount > Self.maxLineBytes {
                throw NNTPError.protocolError("line exceeded \(Self.maxLineBytes) bytes without a terminator")
            }
        }
        defer { lineCursor += 1 }
        return lineQueue[lineCursor]
    }

    private func receiveChunk() async throws -> Data {
        let data = try await rawReceive()
        // Throttle aggregate throughput against the shared bucket (no-op when unlimited).
        await rateLimiter?.take(data.count)
        return data
    }

    private func rawReceive() async throws -> Data {
        guard let connection else { throw NNTPError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: NNTPError.connectionFailed(String(describing: error)))
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: NNTPError.connectionClosed)
                } else {
                    cont.resume(throwing: NNTPError.connectionClosed)
                }
            }
        }
    }
}

/// Guards a continuation so it resumes exactly once, even though `stateUpdateHandler` may fire
/// multiple times off the actor's executor.
private final class ResumeOnce: @unchecked Sendable {
    private var cont: CheckedContinuation<Void, Error>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<Void, Error>) { self.cont = cont }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        guard let c else { return }
        switch result {
        case .success: c.resume()
        case .failure(let error): c.resume(throwing: error)
        }
    }
}

#else
actor NNTPConnection {
    init(config: ServerConfig, rateLimiter: RateLimiter? = nil) {}
    func open() throws {
        throw NNTPError.connectionFailed("Network.framework is unavailable on this platform")
    }
    func close() {}
    func fetchBody(messageID: String) throws -> [Data] { throw NNTPError.notConnected }
    static func isValidMessageID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 1000
            && id.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e && $0 != 60 && $0 != 62 }
    }
}
#endif
