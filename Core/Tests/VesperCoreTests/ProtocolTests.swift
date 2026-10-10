import XCTest
@testable import VesperCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ProtocolTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(type, from: Data(json.utf8)) }

    func testConfiguredManifestAndDeepLink() throws {
        let url = try AddonURL.manifest(" stremio://example.com/token%2Fprivate/manifest.json?key=abc#ignored ")
        XCTAssertEqual(url.absoluteString, "https://example.com/token%2Fprivate/manifest.json?key=abc")
        XCTAssertEqual(try AddonURL.manifest("https://example.com/config/").absoluteString, "https://example.com/config/manifest.json")
        XCTAssertEqual(try AddonURL.manifest("https://example.com").absoluteString, "https://example.com/manifest.json")
        XCTAssertThrowsError(try AddonURL.manifest("file:///etc/passwd"))
        XCTAssertThrowsError(try AddonURL.manifest("https://user:password@example.com/manifest.json"))
    }
    func testResourceEncodingKeepsBaseAndQuery() throws {
        let base = try AddonURL.manifest("https://example.com/private%2Ftoken/manifest.json?auth=secret")
        let url = try AddonURL.resource(manifest: base, resource: "catalog", type: "movie", id: "a/b?x",
            extras: ["search": "Star Wars & +/雪", "skip": "100"])
        XCTAssertEqual(url.absoluteString, "https://example.com/private%2Ftoken/catalog/movie/a%2Fb%3Fx/search=Star%20Wars%20%26%20%2B%2F%E9%9B%AA&skip=100.json?auth=secret")
    }
    func testResourceFiltersHonorDetailedOverrides() throws {
        let manifest = try decode(AddonManifest.self, """
        {"id":"test","name":"Test","version":"1.0.0","types":["movie"],"idPrefixes":["tt"],
        "resources":["meta",{"name":"stream","types":["series"]},{"name":"subtitles","types":["series"],"idPrefixes":["anime:"]}],"catalogs":[]}
        """)
        XCTAssertTrue(manifest.supports("meta", type: "movie", id: "tt123"))
        XCTAssertFalse(manifest.supports("meta", type: "movie", id: "custom:123"))
        XCTAssertTrue(manifest.supports("stream", type: "series", id: "custom:123:1:1"))
        XCTAssertFalse(manifest.supports("stream", type: "movie", id: "tt123"))
        XCTAssertFalse(manifest.supports("subtitles", type: "series", id: "tt123:1:1"))
        XCTAssertTrue(manifest.supports("subtitles", type: "series", id: "anime:1"))
        let roundTrip = try JSONDecoder().decode(AddonManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(manifest, roundTrip)
    }
    func testRequiredAndLegacyCatalogExtras() throws {
        let catalog = try decode(AddonCatalog.self, """
        {"id":"search","type":"movie","extra":[{"name":"search","isRequired":true},{"name":"genre","options":["Drama"]}],"extraSupported":["skip"]}
        """)
        XCTAssertFalse(catalog.canRequest(with: [:]))
        XCTAssertTrue(catalog.canRequest(with: ["search": "arrival"]))
        XCTAssertTrue(catalog.supports("skip"))
        XCTAssertEqual(catalog.genres, ["Drama"])
        let legacy = try decode(AddonCatalog.self, """
        {"id":"legacy","type":"series","extraSupported":["search"],"extraRequired":["search"]}
        """)
        XCTAssertTrue(legacy.supports("search"))
        XCTAssertFalse(legacy.canRequest(with: [:]))
    }
    func testRequiredYearDefaultsAndLegacyGenres() throws {
        let current = try decode(AddonCatalog.self, #"{"id":"year","type":"movie","extra":[{"name":"genre","isRequired":true,"options":["2026","2025"]}]}"#)
        XCTAssertEqual(current.defaultExtras, ["genre": "2026"])
        XCTAssertTrue(current.canRequest(with: current.defaultExtras))
        XCTAssertEqual(current.genreLabel, "Year")
        let legacy = try decode(AddonCatalog.self, #"{"id":"top","type":"movie","genres":["Drama"],"extraRequired":["genre"],"extraSupported":["genre"]}"#)
        XCTAssertEqual(legacy.defaultExtras, ["genre": "Drama"])
        XCTAssertEqual(legacy.genreLabel, "Genre")
    }
    func testEpisodeAndStreamEnvelopes() throws {
        let response = try decode(MetaResponse.self, """
        {"meta":{"id":"tt123","type":"series","name":"Test","videos":[{"id":"tt123:1:2","title":"Second","season":1,"episode":2,"streams":[{"url":"https://example.com/video.mp4"}]}]}}
        """)
        XCTAssertEqual(response.meta?.videos?.first?.label, "S1 · E2")
        XCTAssertEqual(response.meta?.videos?.first?.streams?.first?.url, "https://example.com/video.mp4")
    }
    func testDirectExternalAndUnsupportedSources() throws {
        let direct = try decode(StreamSource.self, #"{"url":"https://example.com/stream.m3u8"}"#)
        XCTAssertEqual(try StreamResolver.resolve(direct, server: ""), .native(URL(string: "https://example.com/stream.m3u8")!))
        let external = try decode(StreamSource.self, #"{"externalUrl":"https://example.com/watch"}"#)
        XCTAssertEqual(try StreamResolver.resolve(external, server: ""), .external(URL(string: "https://example.com/watch")!))
        let unsafe = try decode(StreamSource.self, #"{"externalUrl":"javascript:alert(1)"}"#)
        XCTAssertThrowsError(try StreamResolver.resolve(unsafe, server: ""))
        let unsupported = try decode(StreamSource.self, #"{"rarUrls":["https://example.com/movie.rar"]}"#)
        XCTAssertThrowsError(try StreamResolver.resolve(unsupported, server: ""))
    }
    func testTorrentLargestFileAndTrackers() throws {
        let hash = String(repeating: "a", count: 40)
        let source = try decode(StreamSource.self, """
        {"infoHash":"\(hash)","sources":["tracker:udp://tracker.example:80/announce","dht:node"]}
        """)
        XCTAssertThrowsError(try StreamResolver.resolve(source, server: "")) { XCTAssertEqual($0 as? AddonError, .serverRequired) }
        guard case .native(let url) = try StreamResolver.resolve(source, server: "http://192.168.1.5:11470/base/") else { return XCTFail() }
        XCTAssertEqual(url.path, "/base/\(hash)/-1")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "udp://tracker.example:80/announce")
        let invalid = try decode(StreamSource.self, #"{"infoHash":"../bad"}"#)
        XCTAssertThrowsError(try StreamResolver.resolve(invalid, server: "http://example.com")) { XCTAssertEqual($0 as? AddonError, .invalidTorrent) }
    }
    func testCustomHeadersUseServerProxy() throws {
        let source = try decode(StreamSource.self, #"{"url":"https://media.example:8443/a%20b/movie.m3u8?token=x","behaviorHints":{"proxyHeaders":{"request":{"Referer":"https://origin.example/"}}}}"#)
        XCTAssertThrowsError(try StreamResolver.resolve(source, server: ""))
        guard case .native(let url) = try StreamResolver.resolve(source, server: "http://server.example:11470/base") else { return XCTFail() }
        XCTAssertEqual(url.absoluteString, "http://server.example:11470/base/proxy/d=https%3A%2F%2Fmedia.example%3A8443&h=Referer%3Ahttps%3A%2F%2Forigin.example%2F/a%20b/movie.m3u8?token=x")
    }
    func testSubtitleFormatsAndBoundaries() {
        let srt = "1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i>\r\nWorld\r\n\r\n2\r\n00:00:05,000 --> 00:00:06,000\r\nNext"
        let cues = SubtitleParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(SubtitleParser.text(at: 1, in: cues), "Hello\nWorld")
        XCTAssertNil(SubtitleParser.text(at: 3.5, in: cues))
        XCTAssertEqual(SubtitleParser.parse("WEBVTT\n\n00:01.000 --> 00:03.000 align:center\nCaption").first?.text, "Caption")
        XCTAssertNil(SubtitleParser.timestamp("NaN:12"))
        XCTAssertNil(SubtitleParser.timestamp("00:99:01"))
        XCTAssertTrue(SubtitleParser.parse("not a subtitle").isEmpty)
    }
    func testWatchProgressSeparatesEpisodes() throws {
        let media = try decode(MediaItem.self, #"{"id":"tt123","type":"series","name":"Series"}"#)
        let first = WatchProgress(media: media, videoID: "tt123:1:1", episodeTitle: nil, position: 96, duration: 100)
        let second = WatchProgress(media: media, videoID: "tt123:1:2", episodeTitle: nil, position: 30, duration: 100)
        XCTAssertTrue(first.isFinished)
        XCTAssertFalse(second.isFinished)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(second.fraction, 0.3)
    }
}

final class FixtureURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class ClientTests: XCTestCase {
    private func client() -> AddonClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        return AddonClient(session: URLSession(configuration: config))
    }
    override func tearDown() { FixtureURLProtocol.handler = nil; super.tearDown() }
    func testManifestThenCatalogRequests() async throws {
        FixtureURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("manifest.json") {
                return (200, Data(#"{"id":"fixture","name":"Fixture","version":"1.0.0","types":["movie"],"resources":["catalog"],"catalogs":[{"id":"popular","type":"movie"}]}"#.utf8))
            }
            XCTAssertEqual(request.url!.path, "/configured/catalog/movie/popular/search=hello world.json")
            return (200, Data(#"{"metas":[{"id":"tt1","type":"movie","name":"Example"}]}"#.utf8))
        }
        let api = client()
        let addon = try await api.install("https://fixture.example/configured/manifest.json")
        let items = try await api.catalog(addon, addon.manifest.catalogs[0], extras: ["search": "hello world"])
        XCTAssertEqual(items.first?.name, "Example")
    }
    func testHTTPErrorIsSafeAndActionable() async {
        FixtureURLProtocol.handler = { _ in (403, Data("private-secret-token".utf8)) }
        do { _ = try await client().install("https://fixture.example/private-secret-token/manifest.json"); XCTFail() }
        catch {
            XCTAssertEqual(error as? AddonError, .http(403))
            XCTAssertFalse(error.localizedDescription.contains("private-secret-token"))
        }
    }
    func testConfigurationRequiredIsRejected() async {
        FixtureURLProtocol.handler = { _ in (200, Data(#"{"id":"fixture","name":"Fixture","version":"1.0.0","types":["movie"],"resources":["stream"],"catalogs":[],"behaviorHints":{"configurationRequired":true}}"#.utf8)) }
        do { _ = try await client().install("https://fixture.example/manifest.json"); XCTFail() }
        catch { XCTAssertEqual(error as? AddonError, .configurationRequired) }
    }
    func testMalformedJSON() async {
        FixtureURLProtocol.handler = { _ in (200, Data("<html>down</html>".utf8)) }
        do { _ = try await client().install("https://fixture.example/manifest.json"); XCTFail() }
        catch { XCTAssertEqual(error as? AddonError, .invalidManifest) }
    }
    func testSubtitleVideoIDAndHashExtras() async throws {
        FixtureURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("manifest.json") {
                return (200, Data(#"{"id":"subtitles","name":"Subtitles","version":"1.0.0","types":["series"],"resources":["subtitles"],"catalogs":[]}"#.utf8))
            }
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath
            XCTAssertEqual(path, "/subtitles/series/tt123%3A1%3A2/filename=episode.mkv&videoHash=1234567890abcdef&videoSize=12345.json")
            return (200, Data(#"{"subtitles":[{"id":"en","url":"https://example.com/en.srt","lang":"eng"}]}"#.utf8))
        }
        let api = client()
        let addon = try await api.install("https://fixture.example/manifest.json")
        let stream = try JSONDecoder().decode(StreamSource.self, from: Data(#"{"url":"https://example.com/video.mp4","behaviorHints":{"videoHash":"1234567890abcdef","videoSize":12345,"filename":"episode.mkv"}}"#.utf8))
        let options = try await api.subtitles(addon, type: "series", videoID: "tt123:1:2", stream: stream)
        XCTAssertEqual(options.first?.lang, "eng")
    }
}
