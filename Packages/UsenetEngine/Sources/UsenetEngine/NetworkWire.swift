#if canImport(Network)
import Foundation
import Network

/// Every pending continuation has one owner and is resumed on close, even for a silent peer.
final class NetworkWire: NNTPWire, @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var closed = false
    private var pending: [UUID: @Sendable () -> Void] = [:]
    private static let queue = DispatchQueue(label: "app.vesper.usenet.nntp", attributes: .concurrent)
    init(provider: UsenetProvider) throws {
        _ = try provider.validated()
        guard let port = NWEndpoint.Port(rawValue: UInt16(provider.port)) else {
            throw UsenetError.providerRequired
        }
        let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = 20; tcp.enableKeepalive = true
        let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(provider.host), port: port, using: parameters)
    }
    init(connection: NWConnection) { self.connection = connection }
    private func register<T: Sendable>(_ continuation: CheckedContinuation<T, Error>) -> (UUID, WireResult<T>)
    {
        let id = UUID(), result = WireResult(continuation)
        lock.lock()
        if closed { lock.unlock(); result.finish(.failure(UsenetError.cancelled)); return (id, result) }
        pending[id] = { result.finish(.failure(UsenetError.cancelled)) }; lock.unlock()
        return (id, result)
    }
    private func finished(_ id: UUID) { lock.lock(); pending[id] = nil; lock.unlock() }
    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let (id, result) = register(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: result.finish(.success(())); self?.finished(id)
                case .failed, .waiting, .cancelled:
                    result.finish(.failure(UsenetError.connection)); self?.finished(id)
                default: break
                }
            }
            connection.start(queue: Self.queue)
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let (id, result) = register(continuation)
            connection.send(
                content: data,
                completion: .contentProcessed { [weak self] error in
                    if error == nil {
                        result.finish(.success(()))
                    } else {
                        result.finish(.failure(UsenetError.connection))
                    }
                    self?.finished(id)
                })
        }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let (id, result) = register(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, _, error in
                if error == nil, let data, !data.isEmpty {
                    result.finish(.success(data))
                } else {
                    result.finish(.failure(UsenetError.connection))
                }
                self?.finished(id)
            }
        }
    }
    func close() {
        lock.lock(); closed = true; let callbacks = Array(pending.values); pending = [:]; lock.unlock()
        connection.cancel(); callbacks.forEach { $0() }
    }
    deinit { close() }
}
#endif

import Foundation
final class WireResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
}
