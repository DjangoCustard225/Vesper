import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct FixtureResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var chunkInterval: TimeInterval = 0
    var onChunk: (@Sendable () -> Void)?

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        chunks = [body]
    }
}

/// Each fixture owns its handler; sessions carry only an opaque test identifier.
final class HTTPFixture: @unchecked Sendable {
    private static let maximumRequestBodySize = 1_048_576
    typealias Handler = (URLRequest) throws -> FixtureResponse
    private final class WeakFixture {
        weak var value: HTTPFixture?

        init(_ value: HTTPFixture) { self.value = value }
    }
    private static let registryLock = NSLock()
    private static var registry: [String: WeakFixture] = [:]
    private static let header = "X-Vesper-Test-Fixture"
    private let id = UUID().uuidString
    private let lock = NSLock()
    private var storedHandler: Handler?

    var respond: Handler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    var handler: ((URLRequest) throws -> (Int, Data))? {
        get {
            respond.map { handler in
                { request in
                    let response = try handler(request)
                    return (response.status, response.chunks.reduce(into: Data()) { $0.append($1) })
                }
            }
        }
        set {
            respond = newValue.map { handler in
                { request in
                    let (status, body) = try handler(request)
                    return FixtureResponse(status: status, body: body)
                }
            }
        }
    }

    init() {
        Self.registryLock.lock()
        Self.registry[id] = WeakFixture(self)
        Self.registryLock.unlock()
    }

    deinit {
        Self.registryLock.lock()
        Self.registry[id] = nil
        Self.registryLock.unlock()
    }

    func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id]
        return URLSession(configuration: configuration)
    }

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(id, forHTTPHeaderField: Self.header)
        return request
    }

    fileprivate static func handler(for request: URLRequest) -> Handler? {
        guard let id = request.value(forHTTPHeaderField: header) else { return nil }
        registryLock.lock()
        let fixture = registry[id]?.value
        registryLock.unlock()
        return fixture?.respond
    }

    static func materializingRequestBody(in request: URLRequest) throws -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else { return request }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            guard count > 0 else { break }
            guard body.count + count <= maximumRequestBodySize else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            body.append(contentsOf: buffer[..<count])
        }

        var materialized = request
        materialized.httpBodyStream = nil
        materialized.httpBody = body
        return materialized
    }
}

// Mutable protocol state is locked; response delivery is serialized for FoundationNetworking.
final class FixtureURLProtocol: URLProtocol {
    private struct Work: @unchecked Sendable {
        let handler: HTTPFixture.Handler
        let owner: FixtureURLProtocol
    }
    private struct Owner: @unchecked Sendable { let value: FixtureURLProtocol }
    private static let delivery = DispatchQueue(label: "VesperTests.HTTP.responses")
    private let lock = NSRecursiveLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = HTTPFixture.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let work = Work(handler: handler, owner: self)
        DispatchQueue.global().async {
            do {
                let request = try HTTPFixture.materializingRequestBody(in: work.owner.request)
                work.owner.send(try work.handler(request), index: 0)
            } catch {
                Self.delivery.async {
                    work.owner.deliver { $0.urlProtocol(work.owner, didFailWithError: error) }
                }
            }
        }
    }

    private func send(_ result: FixtureResponse, index: Int) {
        let owner = Owner(value: self)
        Self.delivery.asyncAfter(deadline: .now() + (index == 0 ? 0 : result.chunkInterval)) {
            let receiver = owner.value
            let active = receiver.deliver { client in
                if index == 0, let url = receiver.request.url,
                    let response = HTTPURLResponse(
                        url: url, statusCode: result.status, httpVersion: nil, headerFields: result.headers)
                {
                    client.urlProtocol(receiver, didReceive: response, cacheStoragePolicy: .notAllowed)
                }
                if index < result.chunks.count {
                    result.onChunk?()
                    client.urlProtocol(receiver, didLoad: result.chunks[index])
                } else {
                    client.urlProtocolDidFinishLoading(receiver)
                }
            }
            if active && index < result.chunks.count { receiver.send(result, index: index + 1) }
        }
    }

    @discardableResult private func deliver(_ operation: (URLProtocolClient) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let client else { return false }
        operation(client)
        return true
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
