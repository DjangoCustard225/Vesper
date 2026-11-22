import Foundation

/// A protocol seam for real TLS sockets and deterministic silent-server/cancellation fixtures.
protocol NNTPWire: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

/// One NNTP connection. BODY commands are pipelined: each request is sent as soon as it is
/// issued, and a single reader takes responses off the socket in the order they were sent, so a
/// following article starts arriving the moment the previous one ends instead of a round trip later.
actor NNTPClient {
    private struct Request {
        let id: UUID
        var continuation: CheckedContinuation<[Data], Error>?
        /// Cancelled callers leave their slot; the reader still drains the response to stay in sync.
        var abandoned = false
    }
    private let wire: any NNTPWire
    private let provider: UsenetProvider
    private let deadline: Duration
    private var connected = false
    private var opening: Task<Void, Error>?
    private var framer = LineFramer()
    private var lines: [Data] = []
    private var cursor = 0
    private var queue: [Request] = []
    private var results: [UUID: Result<[Data], Error>] = [:]
    private var cancelledEarly: Set<UUID> = []
    private var sendTail: Task<Void, Error>?
    private var reading = false
    private var failure: UsenetError?
    init(provider: UsenetProvider, wire: any NNTPWire, deadline: Duration = .seconds(20)) {
        self.provider = provider; self.wire = wire; self.deadline = deadline
    }
    /// False once the socket failed or was closed; a pool must not hand it out again.
    var isUsable: Bool { failure == nil }
    func close() { fail(.connection) }
    func test() async throws { try await openOnce() }
    func article(_ id: String) async throws -> [Data] {
        guard !id.isEmpty, id.utf8.count <= 1000,
            id.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e && $0 != 60 && $0 != 62 })
        else { throw UsenetError.invalidNZB }
        try await openOnce()
        try Task.checkCancellation()
        if let failure { throw failure }
        let requestID = UUID()
        queue.append(Request(id: requestID))
        send("BODY <\(id)>")
        startReading()
        let duration = deadline
        return try await withThrowingTaskGroup(of: [Data].self) { group in
            group.addTask { try await self.response(requestID) }
            group.addTask {
                try await Task.sleep(for: duration)
                await self.expire(requestID)
                throw UsenetError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw UsenetError.cancelled }
            return result
        }
    }

    // MARK: Requests

    private func response(_ requestID: UUID) async throws -> [Data] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[Data], Error>) in
                if let result = results.removeValue(forKey: requestID) {
                    continuation.resume(with: result)
                } else if cancelledEarly.remove(requestID) != nil {
                    continuation.resume(throwing: CancellationError())
                } else if let index = queue.firstIndex(where: { $0.id == requestID }) {
                    queue[index].continuation = continuation
                } else {
                    continuation.resume(throwing: failure ?? UsenetError.connection)
                }
            }
        } onCancel: {
            Task { await self.abandon(requestID) }
        }
    }
    private func abandon(_ requestID: UUID) {
        results[requestID] = nil
        guard let index = queue.firstIndex(where: { $0.id == requestID }) else {
            cancelledEarly.insert(requestID); return
        }
        queue[index].abandoned = true
        if let continuation = queue[index].continuation {
            queue[index].continuation = nil; continuation.resume(throwing: CancellationError())
        } else {
            cancelledEarly.insert(requestID)
        }
        // A silent server must not hold the connection forever for a response nobody wants.
        let duration = deadline
        Task {
            try? await Task.sleep(for: duration); self.expire(requestID)
        }
    }
    /// A request still unanswered at its deadline leaves the stream unrecoverable: fail them all.
    private func expire(_ requestID: UUID) {
        if queue.contains(where: { $0.id == requestID }) { fail(.timeout) }
    }
    private func fail(_ error: UsenetError) {
        if failure == nil { failure = error }
        connected = false
        wire.close()
        let pending = queue
        queue = []; results = [:]; cancelledEarly = []
        for request in pending { request.continuation?.resume(throwing: error) }
    }
    /// Sends strictly in issue order, so responses line up with the queue.
    private func send(_ command: String) {
        let previous = sendTail, wire = wire, data = NNTP.command(command)
        sendTail = Task {
            do {
                try await previous?.value
                try await wire.send(data)
            } catch {
                self.fail(.connection); throw error
            }
        }
    }
    private func startReading() {
        guard !reading, !queue.isEmpty, failure == nil else { return }
        reading = true
        Task { await self.readResponses() }
    }
    private func readResponses() async {
        defer { reading = false }
        while let head = queue.first, failure == nil {
            let outcome: Result<[Data], Error>
            do {
                outcome = .success(try await readResponse())
            } catch let error as UsenetError where error == .missingArticle {
                outcome = .failure(error)
            } catch {
                fail((error as? UsenetError) ?? .connection); return
            }
            guard failure == nil, let current = queue.first, current.id == head.id else { return }
            queue.removeFirst()
            if let continuation = current.continuation {
                continuation.resume(with: outcome)
            } else if !current.abandoned {
                results[current.id] = outcome
            }
        }
    }
    private func readResponse() async throws -> [Data] {
        let status = try await statusLine().code
        if [420, 423, 430].contains(status) { throw UsenetError.missingArticle }
        if [480, 481, 482, 483, 502].contains(status) { throw UsenetError.authentication }
        guard status == 222 else { throw UsenetError.connection }
        return try await body()
    }

    // MARK: Connection

    private func openOnce() async throws {
        if connected { return }
        if let failure { throw failure }
        let task: Task<Void, Error>
        if let opening {
            task = opening
        } else {
            task = Task { try await self.bounded { try await self.open() } }
            opening = task
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            fail((error as? UsenetError) ?? .connection)
            throw error
        }
    }
    private func bounded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T
    {
        let wire = wire, duration = deadline
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: duration)
                    wire.close()  // Close before joining the suspended socket task.
                    throw UsenetError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw UsenetError.cancelled }; return result
            }
        } onCancel: {
            wire.close()
        }
    }
    private func open() async throws {
        if connected { return }
        try await wire.connect()
        let greeting = try await statusLine()
        guard greeting.code == 200 || greeting.code == 201 else {
            throw NNTPConnectionLimit.matches(greeting) ? NNTPConnectionLimit() : UsenetError.connection
        }
        if !provider.username.isEmpty {
            try await command("AUTHINFO USER \(provider.username)")
            let first = try await statusLine()
            if first.code != 281 {
                guard first.code == 381 else { throw Self.authenticationFailure(first) }
                try await command("AUTHINFO PASS \(provider.password)")
                let reply = try await statusLine()
                guard reply.code == 281 else { throw Self.authenticationFailure(reply) }
            }
        }
        connected = true
    }
    /// Providers report "too many connections" through auth and greeting replies; that is a
    /// capacity limit for the pool to adapt to, not wrong credentials.
    private static func authenticationFailure(_ status: NNTPStatus) -> Error {
        NNTPConnectionLimit.matches(status) ? NNTPConnectionLimit() : UsenetError.authentication
    }
    private func command(_ value: String) async throws { try await wire.send(NNTP.command(value)) }
    private func statusLine() async throws -> NNTPStatus {
        guard let value = NNTPStatus(line: try await nextLine()) else { throw UsenetError.connection }
        return value
    }
    private func nextLine() async throws -> Data {
        while cursor >= lines.count {
            lines = []; cursor = 0
            let chunk = try await wire.receive()
            guard !chunk.isEmpty else { throw UsenetError.connection }
            lines = framer.append(chunk)
            guard framer.pendingCount <= 64 * 1024 else { throw UsenetError.corrupt }
        }
        defer { cursor += 1 }; return lines[cursor]
    }
    private func body() async throws -> [Data] {
        var result: [Data] = [], size = 0
        while true {
            let line = try await nextLine()
            switch NNTP.processBodyLine(line) {
            case .terminator: return result
            case .content(let bytes):
                guard bytes.count <= 8 * 1024 * 1024 - size else { throw UsenetError.corrupt }
                guard result.count < 131_072 else { throw UsenetError.corrupt }
                size += bytes.count; result.append(bytes)
            }
        }
    }
}

public actor NNTPPool: ArticleSource {
    private struct Waiter {
        let id: UUID
        let messageID: String
        var priority: ArticlePriority
        let continuation: CheckedContinuation<NNTPClient, Error>
    }
    private let provider: UsenetProvider
    private let factory: (@Sendable () throws -> NNTPClient)?
    /// Requests allowed on one connection at once (1 disables pipelining).
    private let depth: Int
    /// Starts at the configured count and drops to what the provider actually allows.
    private var limit: Int
    private var clients: [ObjectIdentifier: NNTPClient] = [:]
    private var load: [ObjectIdentifier: Int] = [:]
    /// Connections being opened ahead of demand; they count against the limit.
    private var warming = 0
    private var active: [UUID: NNTPClient] = [:]
    private var waiting: [Waiter] = []
    private var promoted: Set<String> = []
    private var stopped = false
    private var count: Int { clients.count + warming }
    public init(provider: UsenetProvider) throws {
        self.provider = try provider.validated(); limit = self.provider.connections; factory = nil; depth = 2
    }
    init(
        provider: UsenetProvider, pipelineDepth: Int = 2,
        factory: @escaping @Sendable () throws -> NNTPClient
    ) throws {
        self.provider = try provider.validated(); limit = self.provider.connections; self.factory = factory
        depth = max(1, pipelineDepth)
    }
    /// The connection count allowed, after any reduction the provider forced.
    public var connectionLimit: Int { limit }
    var openConnections: Int { clients.count }
    private func makeClient() throws -> NNTPClient {
        if let factory { return try factory() }
        #if canImport(Network)
        return NNTPClient(provider: provider, wire: try NetworkWire(provider: provider))
        #else
        throw UsenetError.unsupported
        #endif
    }
    public func article(_ messageID: String, priority: ArticlePriority) async throws -> [Data] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            let client = try await acquire(id: id, messageID: messageID, priority: priority)
            do {
                try Task.checkCancellation()
                let value = try await client.article(messageID)
                release(id, reusable: true); return value
            } catch {
                // A missing article or a cancelled request leaves a healthy socket open for reuse.
                let usable = await client.isUsable
                if error is NNTPConnectionLimit {
                    // Keep the connections that already work; the caller retries on one of them.
                    limit = max(1, min(limit, count - 1))
                }
                release(id, reusable: usable && !(error is NNTPConnectionLimit))
                if error is CancellationError { throw error }
                throw (error as? UsenetError) ?? UsenetError.connection
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    /// Opens connections before they are needed, so login round trips are not paid at playback start.
    public func warm(_ connections: Int) async {
        let wanted = min(connections, limit - count)
        guard wanted > 0, !stopped else { return }
        warming += wanted
        for _ in 0..<wanted {
            Task {
                let client: NNTPClient
                do { client = try self.makeClient() } catch { self.warming -= 1; return }
                do {
                    try await client.test()
                    self.warming -= 1
                    guard !self.stopped, self.clients.count < self.limit else { await client.close(); return }
                    let key = ObjectIdentifier(client)
                    self.clients[key] = client; self.load[key] = 0
                    self.dispatch()
                } catch {
                    self.warming -= 1
                    if error is NNTPConnectionLimit { self.limit = max(1, min(self.limit, self.count)) }
                    await client.close()
                    self.dispatch()
                }
            }
        }
    }
    public func test() async throws {
        let client = try await acquire(id: UUID(), messageID: "", priority: .playback)
        do { try await client.test(); await stop() } catch {
            await stop()
            throw error is NNTPConnectionLimit ? UsenetError.connection : error
        }
    }
    private func acquire(id: UUID, messageID: String, priority: ArticlePriority) async throws -> NNTPClient {
        try Task.checkCancellation()
        guard !stopped else { throw UsenetError.cancelled }
        let priority: ArticlePriority = promoted.remove(messageID) != nil ? .playback : priority
        if waiting.isEmpty, let client = try available(for: priority) { assign(id, client); return client }
        return try await withCheckedThrowingContinuation {
            waiting.append(Waiter(id: id, messageID: messageID, priority: priority, continuation: $0))
            dispatch()
        }
    }
    /// An idle connection first, then a new one, then a second request on the least busy socket.
    /// Playback demand is never queued behind another article: it is what the player is waiting
    /// on, and a repeat request for a slow article must not land on the socket that is stalling.
    private func available(for priority: ArticlePriority) throws -> NNTPClient? {
        if let key = load.first(where: { $0.value == 0 })?.key, let client = clients[key] { return client }
        if count < limit {
            let client = try makeClient(), key = ObjectIdentifier(client)
            clients[key] = client; load[key] = 0
            return client
        }
        if depth > 1, priority != .playback,
            let key = load.filter({ $0.value < depth }).min(by: { $0.value < $1.value })?.key
        {
            return clients[key]
        }
        return nil
    }
    private func assign(_ id: UUID, _ client: NNTPClient) {
        active[id] = client; load[ObjectIdentifier(client), default: 0] += 1
    }
    public func promote(_ messageID: String) {
        let indices = waiting.indices.filter { waiting[$0].messageID == messageID }
        if indices.isEmpty {
            promoted.insert(messageID)
        } else {
            for index in indices { waiting[index].priority = .playback }
        }
    }
    private func release(_ id: UUID, reusable: Bool) {
        guard let client = active.removeValue(forKey: id) else { return }
        let key = ObjectIdentifier(client)
        if clients[key] != nil {
            load[key] = max(0, (load[key] ?? 1) - 1)
            if !reusable || stopped {
                clients[key] = nil; load[key] = nil
                Task { await client.close() }
            }
        }
        dispatch()
    }
    private func dispatch() {
        while !waiting.isEmpty, !stopped {
            let priority = waiting.map(\.priority.rawValue).max()!
            let index = waiting.firstIndex { $0.priority.rawValue == priority }!
            do {
                guard let client = try available(for: waiting[index].priority) else { return }
                let next = waiting.remove(at: index)
                assign(next.id, client); next.continuation.resume(returning: client)
            } catch {
                waiting.remove(at: index).continuation.resume(throwing: error)
            }
        }
    }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
    public func stop() async {
        stopped = true; promoted = []
        let open = Array(clients.values); clients = [:]; load = [:]
        for waiter in waiting { waiter.continuation.resume(throwing: UsenetError.cancelled) }; waiting = []
        for client in open { await client.close() }
    }
}

/// A provider refused another connection because the account's connection limit was reached.
struct NNTPConnectionLimit: Error {
    static func matches(_ status: NNTPStatus) -> Bool {
        guard [400, 481, 482, 502].contains(status.code) else { return false }
        let text = status.text.lowercased()
        return ["too many", "connection limit", "connections", "max conn", "maximum"].contains {
            text.contains($0)
        }
    }
}
