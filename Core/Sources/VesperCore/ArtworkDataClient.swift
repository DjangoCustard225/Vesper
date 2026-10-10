import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor ArtworkDataClient {
    private let session: URLSession
    private let memory = NSCache<NSURL, NSData>()
    private var requests: [URL: Task<Data, Error>] = [:]
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.default
            configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024, diskPath: "VesperArtwork")
            configuration.httpCookieStorage = nil
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 45
            self.session = URLSession(configuration: configuration)
        }
        memory.totalCostLimit = 24 * 1024 * 1024
        memory.countLimit = 150
    }
    deinit { session.invalidateAndCancel() }

    public func data(for url: URL) async throws -> Data {
        _ = try AddonURL.http(url.absoluteString)
        try Task.checkCancellation()
        if let data = memory.object(forKey: url as NSURL) { return data as Data }
        if let task = requests[url] {
            let data = try await task.value
            try Task.checkCancellation()
            return data
        }
        let session = session
        let task = Task<Data, Error> {
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), !data.isEmpty else {
                throw URLError(.badServerResponse)
            }
            return data
        }
        requests[url] = task
        do {
            let data = try await task.value
            memory.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            requests[url] = nil
            try Task.checkCancellation()
            return data
        } catch {
            requests[url] = nil
            throw error
        }
    }
}
