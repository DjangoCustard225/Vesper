import Foundation

/// A protocol seam for real TLS sockets and deterministic silent-server/cancellation fixtures.
protocol NNTPWire: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

actor NNTPClient {
    private let wire: any NNTPWire
    private let provider: UsenetProvider
    private let deadline: Duration
    private var connected = false
    private var framer = LineFramer()
    private var lines: [Data] = []
    private var cursor = 0
    init(provider: UsenetProvider, wire: any NNTPWire, deadline: Duration = .seconds(20)) {
        self.provider = provider; self.wire = wire; self.deadline = deadline
    }
    func close() { wire.close(); connected = false }
    func test() async throws { try await bounded { try await self.open() } }
    func article(_ id: String) async throws -> [Data] {
        try await bounded {
            try await self.open()
            guard !id.isEmpty, id.utf8.count <= 1000,
                id.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e && $0 != 60 && $0 != 62 })
            else { throw UsenetError.invalidNZB }
            try await self.command("BODY <\(id)>")
            let status = try await self.status()
            if [420, 423, 430].contains(status) { throw UsenetError.missingArticle }
            if [480, 481, 482, 483, 502].contains(status) { throw UsenetError.authentication }
            guard status == 222 else { throw UsenetError.connection }
            return try await self.body()
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
        let greeting = try await status()
        guard greeting == 200 || greeting == 201 else { throw UsenetError.connection }
        if !provider.username.isEmpty {
            try await command("AUTHINFO USER \(provider.username)")
            let first = try await status()
            if first != 281 {
                guard first == 381 else { throw UsenetError.authentication }
                try await command("AUTHINFO PASS \(provider.password)")
                guard try await status() == 281 else { throw UsenetError.authentication }
            }
        }
        connected = true
    }
    private func command(_ value: String) async throws { try await wire.send(NNTP.command(value)) }
    private func status() async throws -> Int {
        guard let value = NNTPStatus(line: try await nextLine()) else { throw UsenetError.connection };
        return value.code
    }
    private func nextLine() async throws -> Data {
        while cursor >= lines.count {
            try Task.checkCancellation()
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
    private var count = 0
    private var idle: [NNTPClient] = []
    private var active: [UUID: NNTPClient] = [:]
    private var waiting: [Waiter] = []
    private var promoted: Set<String> = []
    private var stopped = false
    public init(provider: UsenetProvider) throws { self.provider = try provider.validated(); factory = nil }
    init(provider: UsenetProvider, factory: @escaping @Sendable () throws -> NNTPClient) throws {
        self.provider = try provider.validated(); self.factory = factory
    }
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
                await client.close(); release(id, reusable: false)
                if error is CancellationError { throw error }
                throw (error as? UsenetError) ?? UsenetError.connection
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    public func test() async throws {
        let client = try await acquire(id: UUID(), messageID: "", priority: .playback)
        do { try await client.test(); await stop() } catch { await stop(); throw error }
    }
    private func acquire(id: UUID, messageID: String, priority: ArticlePriority) async throws -> NNTPClient {
        try Task.checkCancellation()
        guard !stopped else { throw UsenetError.cancelled }
        let priority: ArticlePriority = promoted.remove(messageID) != nil ? .playback : priority
        if let client = idle.popLast() { active[id] = client; return client }
        if count < provider.connections {
            let client = try makeClient(); count += 1; active[id] = client; return client
        }
        return try await withCheckedThrowingContinuation {
            waiting.append(Waiter(id: id, messageID: messageID, priority: priority, continuation: $0))
        }
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
        if reusable, !stopped { idle.append(client) } else { count -= 1 }
        dispatch()
    }
    private func dispatch() {
        while !waiting.isEmpty, !stopped, !idle.isEmpty || count < provider.connections {
            let priority = waiting.map(\.priority.rawValue).max()!
            let next = waiting.remove(at: waiting.firstIndex { $0.priority.rawValue == priority }!)
            do {
                let client: NNTPClient
                if let existing = idle.popLast() {
                    client = existing
                } else {
                    client = try makeClient(); count += 1
                }
                active[next.id] = client; next.continuation.resume(returning: client)
            } catch { next.continuation.resume(throwing: error) }
        }
    }
    private func cancel(_ id: UUID) async {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        if let client = active[id] { await client.close() }
    }
    public func stop() async {
        stopped = true; promoted = []
        let clients = idle + Array(active.values); idle = []
        for waiter in waiting { waiter.continuation.resume(throwing: UsenetError.cancelled) }; waiting = []
        for client in clients { await client.close() }
    }
}
