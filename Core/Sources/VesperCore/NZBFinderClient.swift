import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public actor NZBFinderClient {
    private let session: URLSession
    private let ownsSession: Bool
    private let transport: HTTPTransport
    private let pages = SharedRequestPool<NZBSearchPage>()
    private let capRequests = SharedRequestPool<NewznabCapabilities>()
    private var cache = ExpiringCache<NZBSearchPage>(lifetime: 300, capacity: 32)
    private var capsCache = ExpiringCache<NewznabCapabilities>(lifetime: 24 * 3600, capacity: 2)
    private var cooldown: [String: Date] = [:]
    private var generation = UUID()
    public init(session: URLSession? = nil) {
        ownsSession = session == nil
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil; config.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(
                configuration: config, delegate: NZBFinderRedirectGuard(), delegateQueue: nil)
        }
        transport = HTTPTransport(
            session: self.session, policy: RetryPolicy(attempts: 1, budget: 25), requestTimeout: 20)
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }
    public func invalidate() async {
        generation = UUID(); cache.removeAll(); capsCache.removeAll()
        await pages.cancelAll(); await capRequests.cancelAll()
    }
    public func verify(apiKey: String) async throws {
        _ = try await capabilities(apiKey)
        let data = try await fetch(
            [
                URLQueryItem(name: "t", value: "search"), URLQueryItem(name: "cat", value: "2000,5000"),
                URLQueryItem(name: "limit", value: "1"),
            ], apiKey: apiKey, limit: 4 * 1024 * 1024)
        do {
            guard try NewznabDocument.parse(data).root == "rss" else { throw NZBFinderError.invalidResponse }
        } catch { throw noted(error, apiKey: apiKey) }
    }
    public func search(
        _ context: NZBSearchContext, apiKey: String, cursor: NZBSearchCursor? = nil, refresh: Bool = false
    )
        async throws -> NZBSearchPage
    {
        let fingerprint = try credential(apiKey)
        let key = ResponseCache.fingerprint(
            fingerprint + context.key + ":\(cursor?.offset ?? 0):\(cursor?.titleSearch ?? false)")
        if !refresh, let value = cache.value(for: key) { return value }
        try available(fingerprint)
        let current = generation
        let result = try await pages.value(for: key) { [self] in
            do { return try await performSearch(context, apiKey: apiKey, cursor: cursor) } catch {
                throw await noted(error, apiKey: apiKey)
            }
        }
        try Task.checkCancellation(); guard generation == current else { throw CancellationError() }
        cache.insert(result, for: key); return result
    }
    public func nzb(_ release: NZBRelease, apiKey: String) async throws -> Data {
        try await download(release, apiKey: apiKey).data
    }
    public func download(_ release: NZBRelease, apiKey: String) async throws -> NZBDownload {
        guard !release.id.isEmpty, release.id.utf8.count <= 256,
            release.id.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
            })
        else { throw NZBFinderError.missingRelease }
        let current = generation
        let result = try await response(
            [URLQueryItem(name: "t", value: "get"), URLQueryItem(name: "id", value: release.id)],
            apiKey: apiKey, limit: 16 * 1024 * 1024)
        let data = result.0
        do {
            guard try NewznabDocument.parse(data, probeNZB: true).root == "nzb" else {
                throw NZBFinderError.invalidResponse
            }
        } catch { throw noted(error, apiKey: apiKey) }
        try Task.checkCancellation(); guard generation == current else { throw CancellationError() };
        return NZBDownload(data: data, password: result.1.value(forHTTPHeaderField: "x-dnzb-password"))
    }
    private func performSearch(_ context: NZBSearchContext, apiKey: String, cursor: NZBSearchCursor?)
        async throws -> NZBSearchPage
    {
        let caps = try await capabilities(apiKey), count = min(50, caps.maximum), offset = cursor?.offset ?? 0
        guard offset >= 0 else { throw NZBFinderError.invalidResponse }
        var titleSearch = cursor?.titleSearch ?? false
        var query = try caps.query(context, titleOnly: titleSearch)
        titleSearch = query.contains { $0.name == "q" }
        func page(_ query: [URLQueryItem]) async throws -> NewznabDocument {
            let data = try await fetch(
                query + [
                    URLQueryItem(name: "limit", value: String(count)),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "extended", value: "1"),
                ], apiKey: apiKey, limit: 4 * 1024 * 1024)
            let result = try NewznabDocument.parse(data)
            guard result.root == "rss", result.offset == nil || result.offset == offset else {
                throw NZBFinderError.invalidResponse
            }; return result
        }
        var document = try await page(query)
        func matches(_ document: NewznabDocument, titleSearch: Bool) -> [NZBRelease] {
            var seen = Set<String>()
            return document.items.compactMap { $0.release(context: context, titleSearch: titleSearch) }.filter
            { seen.insert($0.id).inserted }
        }
        var releases = matches(document, titleSearch: titleSearch)
        if cursor == nil, releases.isEmpty, !titleSearch,
            let fallback = try? caps.query(context, titleOnly: true)
        {
            query = fallback; titleSearch = true; document = try await page(query)
            releases = matches(document, titleSearch: true)
        }
        let (nextOffset, overflow) = offset.addingReportingOverflow(document.items.count)
        let more =
            !overflow && nextOffset < 500 && !document.items.isEmpty
            && (document.total.map { nextOffset < $0 } ?? (document.items.count == count))
        return NZBSearchPage(
            releases: releases,
            next: more ? NZBSearchCursor(offset: nextOffset, titleSearch: titleSearch) : nil)
    }
    private func capabilities(_ apiKey: String) async throws -> NewznabCapabilities {
        let key = try credential(apiKey)
        if let value = capsCache.value(for: key) { return value }
        let current = generation
        let result = try await capRequests.value(for: key) { [self] in
            do {
                let data = try await fetch(
                    [URLQueryItem(name: "t", value: "caps")], apiKey: apiKey, limit: 1024 * 1024)
                let document = try NewznabDocument.parse(data)
                guard document.root == "caps",
                    !document.capabilities.search.isEmpty || !document.capabilities.movie.isEmpty
                        || !document.capabilities.tv.isEmpty
                else { throw NZBFinderError.unsupported }
                return document.capabilities
            } catch { throw await noted(error, apiKey: apiKey) }
        }
        guard generation == current else { throw CancellationError() }; capsCache.insert(result, for: key);
        return result
    }
    private func credential(_ apiKey: String) throws -> String {
        guard !apiKey.isEmpty, apiKey.utf8.count <= 1024,
            !apiKey.contains(where: { $0.isWhitespace || $0.isNewline })
        else { throw NZBFinderError.missingKey }
        return ResponseCache.fingerprint(apiKey)
    }
    private func available(_ key: String) throws {
        if let until = cooldown[key], until > Date() { throw NZBFinderError.rateLimited }
    }
    private func noted(_ error: Error, apiKey: String) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return CancellationError()
        }
        if error as? NZBFinderError == .rateLimited {
            let key = ResponseCache.fingerprint(apiKey)
            if cooldown[key].map({ $0 > Date() }) != true { cooldown[key] = Date().addingTimeInterval(60) }
        }
        if (error as? URLError)?.code == .dataLengthExceedsMaximum { return NZBFinderError.invalidResponse }
        return (error as? NZBFinderError) ?? NZBFinderError.unavailable
    }
    private func fetch(_ parameters: [URLQueryItem], apiKey: String, limit: Int) async throws -> Data {
        try await response(parameters, apiKey: apiKey, limit: limit).0
    }
    private func response(_ parameters: [URLQueryItem], apiKey: String, limit: Int) async throws -> (
        Data, HTTPURLResponse
    ) {
        let key = try credential(apiKey); try available(key)
        var parts = URLComponents(string: "https://nzbfinder.ws/api")!
        parts.queryItems =
            parameters + [URLQueryItem(name: "apikey", value: apiKey), URLQueryItem(name: "o", value: "xml")]
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/xml, application/x-nzb, text/xml", forHTTPHeaderField: "Accept")
        request.setValue("Vesper", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await transport.data(
                for: request, operation: .indexer, byteLimit: limit)
            if response.statusCode == 429 {
                let raw = response.value(forHTTPHeaderField: "Retry-After") ?? ""
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX");
                formatter.timeZone = TimeZone(secondsFromGMT: 0);
                formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
                let delay = Double(raw) ?? formatter.date(from: raw)?.timeIntervalSinceNow ?? 60
                cooldown[key] = Date().addingTimeInterval(delay.isFinite ? max(1, delay) : 60)
                throw NZBFinderError.rateLimited
            }
            guard response.statusCode == 200 else {
                // Some indexers encode authentication errors as XML even with an HTTP failure status.
                if let text = String(data: data.prefix(512), encoding: .utf8), text.contains("<error") {
                    _ = try NewznabDocument.parse(data)
                }
                switch response.statusCode {
                case 401: throw NZBFinderError.unauthorized;
                case 404: throw NZBFinderError.missingRelease;
                default: throw NZBFinderError.unavailable
                }
            }
            return (data, response)
        } catch { throw noted(error, apiKey: apiKey) }
    }
}

final class NZBFinderRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func permits(_ url: URL?) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return parts.scheme == "https" && parts.host?.lowercased() == "nzbfinder.ws"
            && (parts.port == nil || parts.port == 443) && parts.user == nil && parts.password == nil
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.permits(request.url) ? request : nil)
    }
}
