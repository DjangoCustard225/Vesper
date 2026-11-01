import Foundation
#if canImport(Network)
import Network

/// A tokenized, loopback-only HTTP range endpoint. Provider credentials never enter its URL.
public actor UsenetHTTPServer {
    private var listener: NWListener?
    private var peers: [UUID: NetworkWire] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var session: UsenetSession?
    private var video: UsenetVideo?
    private var path = ""
    private var port: UInt16 = 0
    private var onFailure: (@Sendable (UsenetError) -> Void)?
    private static let queue = DispatchQueue(label: "app.vesper.usenet.http", attributes: .concurrent)
    public init() {}
    public func start(
        video: UsenetVideo, session: UsenetSession,
        onFailure: @escaping @Sendable (UsenetError) -> Void = { _ in }
    ) async throws -> URL {
        await stop()
        self.session = session; self.video = video; self.onFailure = onFailure
        let ext = (video.name as NSString).pathExtension.lowercased()
        path = "/" + UUID().uuidString + "/video." + (UsenetVideo.isVideo(video.name) ? ext : "bin")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        let selectedPath = path
        let url: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = WireResult<URL>(continuation)
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready:
                        guard let port = listener?.port?.rawValue,
                            let url = URL(string: "http://127.0.0.1:\(port)\(selectedPath)")
                        else { result.finish(.failure(UsenetError.connection)); return }
                        result.finish(.success(url))
                    case .failed, .cancelled: result.finish(.failure(UsenetError.connection))
                    default: break
                    }
                }
                listener.start(queue: Self.queue)
            }
        } onCancel: {
            listener.cancel()
        }
        guard !Task.isCancelled, self.listener === listener else { throw CancellationError() }
        port = listener.port!.rawValue
        return url
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < 12, session != nil else { connection.cancel(); return }
        let id = UUID(), peer = NetworkWire(connection: connection)
        peers[id] = peer
        tasks[id] = Task { await self.handle(id, peer: peer) }
    }
    private func headers(_ peer: NetworkWire) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await peer.connect()
                var bytes = Data()
                while bytes.count <= 16 * 1024 {
                    bytes.append(try await peer.receive())
                    if let end = bytes.range(of: Data("\r\n\r\n".utf8)) {
                        return Data(bytes[..<end.upperBound])
                    }
                }
                throw UsenetError.invalidRange
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15)); peer.close(); throw UsenetError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
    private func handle(_ id: UUID, peer: NetworkWire) async {
        defer { peer.close(); peers[id] = nil; tasks[id] = nil }
        var started = false
        do {
            let request = try LocalHTTPRequest(try await headers(peer))
            guard let video, let session, request.path == path,
                request.headers["host"] == "127.0.0.1:\(port)",
                request.headers["content-length"].map({ $0 == "0" }) ?? true
            else {
                try await peer.send(
                    Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8));
                return
            }
            let range: HTTPByteRange
            do { range = try HTTPByteRange.resolve(request.headers["range"], size: video.length) } catch {
                try await peer.send(
                    Data(
                        "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(video.length)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            .utf8));
                return
            }
            var cursor = range.start
            var first = Data()
            if request.method == "GET" {
                first = try await session.read(
                    video: video, offset: cursor, count: Int(min(256 * 1024, range.count)))
            }
            let partial = request.headers["range"] != nil
            var response =
                "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(video.mimeType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(range.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
            if partial { response += "Content-Range: bytes \(range.start)-\(range.end)/\(video.length)\r\n" }
            response += "\r\n"
            try await peer.send(Data(response.utf8)); started = true
            if request.method == "HEAD" { return }
            try await peer.send(first); cursor += Int64(first.count)
            while cursor <= range.end {
                try Task.checkCancellation()
                let data = try await session.read(
                    video: video, offset: cursor, count: Int(min(256 * 1024, range.end - cursor + 1)))
                try await peer.send(data); cursor += Int64(data.count)
            }
        } catch {
            if let error = error as? UsenetError,
                [.missingArticle, .corrupt, .storage, .authentication, .timeout].contains(error)
            {
                onFailure?(error)
            }
            if !started {
                try? await peer.send(
                    Data(
                        "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            .utf8))
            }
        }
    }
    public func stop() async {
        listener?.cancel(); listener = nil
        tasks.values.forEach { $0.cancel() }; peers.values.forEach { $0.close() }; tasks = [:]; peers = [:]
        let previous = session; session = nil; video = nil; onFailure = nil
        await previous?.stop()
    }
}
#else
public actor UsenetHTTPServer {
    public init() {}
    public func start(
        video: UsenetVideo, session: UsenetSession,
        onFailure: @escaping @Sendable (UsenetError) -> Void = { _ in }
    ) async throws -> URL { throw UsenetError.unsupported }
    public func stop() async {}
}
#endif
