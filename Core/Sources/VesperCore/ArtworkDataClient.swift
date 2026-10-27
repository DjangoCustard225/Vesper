import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor ArtworkDataClient {
    private let session: URLSession
    private let ownsSession: Bool
    private let memory = NSCache<NSURL, NSData>()
    private var requests = SharedRequestPool<Data>()
    private var generation = UUID()
    private let limiter = PriorityRequestLimiter(limit: 6, prefetchLimit: 2)

    public init(session: URLSession? = nil) {
        ownsSession = session == nil
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache(
                memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024, diskPath: "VesperArtwork")
            configuration.httpCookieStorage = nil
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration)
        }
        memory.totalCostLimit = 24 * 1024 * 1024
        memory.countLimit = 150
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    public func clearMemory() { memory.removeAllObjects() }

    public func clearCache() async {
        generation = UUID()
        let previous = requests
        requests = SharedRequestPool()
        memory.removeAllObjects()
        await previous.cancelAll()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    func subscriberCount(for url: URL) async -> Int {
        await requests.subscriberCount(for: url.absoluteString)
    }

    public func promote(_ url: URL) async {
        await requests.promote(url.absoluteString)
        await limiter.promote(url.absoluteString)
    }

    public func data(for url: URL, priority: ArtworkPriority = .visible) async throws -> Data {
        _ = try AddonURL.http(url.absoluteString)
        try Task.checkCancellation()
        if let data = memory.object(forKey: url as NSURL) { return data as Data }
        let session = session, limiter = limiter, token = generation
        return try await requests.value(
            for: url.absoluteString, priority: priority,
            onPromotion: { await limiter.promote(url.absoluteString) }
        ) { demand in
            let queued = ArtworkTimer()
            let (data, queueTime) = try await limiter.run(key: url.absoluteString, demand: demand) {
                let queueTime = queued.milliseconds
                let (data, response) = try await HTTPTransport(session: session, requestTimeout: 20)
                    .data(for: URLRequest(url: url), operation: .artwork)
                try Task.checkCancellation()
                guard (200..<300).contains(response.statusCode), !data.isEmpty else {
                    throw URLError(.badServerResponse)
                }
                return (data, queueTime)
            }
            await DiagnosticRecorder.shared.recordArtwork(
                .downloadQueue, milliseconds: queueTime, priority: demand.priority)
            try Task.checkCancellation()
            try await self.finished(url, data: data, token: token)
            return data
        }
    }

    private func finished(_ url: URL, data: Data, token: UUID) throws {
        guard token == generation else { throw CancellationError() }
        memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
    }
}
