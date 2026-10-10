import XCTest
@testable import VesperCore

final class ExternalPlayerTests: XCTestCase {
    func testPlayerURLsPreserveSignedNestedStreamURLs() throws {
        let stream = URL(string: "https://video.example/雪%20movie.mkv?token=a%2Fb+q&expires=42&sign=x%3Dy#fragment")!
        for player in [VideoPlayer.vlc, .infuse] {
            let launch = try player.launchURL(for: stream, position: 125.7)
            let components = try XCTUnwrap(URLComponents(url: launch, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, player == .vlc ? "vlc-x-callback" : "infuse")
            XCTAssertEqual(components.host, "x-callback-url")
            XCTAssertEqual(components.path, player == .vlc ? "/stream" : "/play")
            XCTAssertEqual(components.queryItems?.first { $0.name == "url" }?.value, stream.absoluteString)
            XCTAssertEqual(components.queryItems?.first { $0.name == "x-success" }?.value, "vesper://player-return")
            XCTAssertEqual(components.queryItems?.first { $0.name == "position" }?.value, player == .infuse ? "125" : nil)
        }
    }
    func testSavedPlayerMigrationRetainsExternalChoices() {
        XCTAssertEqual(VideoPlayer.preferred(storedValue: "vlc"), .vlc)
        XCTAssertEqual(VideoPlayer.preferred(storedValue: "infuse"), .infuse)
        for value in [nil, "builtIn", "unknown"] {
            XCTAssertEqual(VideoPlayer.preferred(storedValue: value), .vlc)
        }
        XCTAssertEqual(VideoPlayer.allCases, [.vlc, .infuse])
    }
    func testPlayerRejectsUnsupportedProtocolsAndUnsafePositions() throws {
        XCTAssertThrowsError(try VideoPlayer.vlc.launchURL(for: URL(string: "file:///etc/passwd")!))
        for position in [Double.nan, .infinity, -1, 0] {
            let launch = try VideoPlayer.infuse.launchURL(for: URL(string: "https://video.example/file")!, position: position)
            XCTAssertNil(URLComponents(url: launch, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "position" })
        }
    }
    func testResolvedProxyURLIsPassedToExternalPlayerIntact() throws {
        let source = try JSONDecoder().decode(StreamSource.self, from: Data(#"{"url":"https://source.example/video.mkv?token=a%2Fb","behaviorHints":{"proxyHeaders":{"request":{"Authorization":"Bearer private"}}}}"#.utf8))
        guard case .native(let proxy) = try StreamResolver.resolve(source, server: "http://192.168.1.10:11470") else { return XCTFail("Expected proxy stream") }
        let launch = try VideoPlayer.infuse.launchURL(for: proxy)
        let nested = URLComponents(url: launch, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
        XCTAssertEqual(nested, proxy.absoluteString)
        XCTAssertEqual(proxy.host, "192.168.1.10")
    }
    func testCinemetaMigrationKeepsOtherAddons() throws {
        func addon(_ id: String, host: String) throws -> InstalledAddon {
            let manifest = try JSONDecoder().decode(AddonManifest.self, from: Data("""
            {"id":"\(id)","name":"Provider","version":"1.0","resources":["stream"],"types":["movie"],"catalogs":[]}
            """.utf8))
            return InstalledAddon(manifestURL: URL(string: "https://\(host)/manifest.json")!, manifest: manifest)
        }
        let saved = try [addon("com.linvo.cinemeta", host: "mirror.example"), addon("other", host: "v3-cinemeta.strem.io"), addon("my.streams", host: "streams.example")]
        XCTAssertEqual(saved.filter { !AddonPolicy.isCinemeta($0) }.map(\.manifest.id), ["my.streams"])
    }
}
