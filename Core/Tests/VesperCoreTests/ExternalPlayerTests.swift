import XCTest
@testable import VesperCore

final class ExternalPlayerTests: XCTestCase {
    func testPlayerURLsPreserveSignedNestedStreamURLs() throws {
        let stream = URL(string: "https://video.example/雪%20movie.mkv?token=a%2Fb+q&expires=42&sign=x%3Dy#fragment")!
        for player in [VideoPlayer.vlc, .infuse] {
            let launch = try player.launchURL(for: stream)
            let components = try XCTUnwrap(URLComponents(url: launch, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, player == .vlc ? "vlc-x-callback" : "infuse")
            XCTAssertEqual(components.host, "x-callback-url")
            XCTAssertEqual(components.path, player == .vlc ? "/stream" : "/play")
            XCTAssertEqual(components.queryItems?.first { $0.name == "url" }?.value, stream.absoluteString)
            XCTAssertEqual(components.queryItems?.map(\.name), ["url"])
        }
    }
    func testSavedPlayerMigrationRetainsExternalChoices() {
        XCTAssertEqual(VideoPlayer.preferred(storedValue: "vlc"), .vlc)
        XCTAssertEqual(VideoPlayer.preferred(storedValue: "infuse"), .infuse)
        for value in [nil, "builtIn", "unknown"] {
            XCTAssertEqual(VideoPlayer.preferred(storedValue: value), .builtIn)
        }
        XCTAssertEqual(VideoPlayer.allCases, [.builtIn, .vlc, .infuse])
        XCTAssertEqual(VideoPlayer.externalPlayers, [.vlc, .infuse])
    }
    func testBuiltInPlayerDoesNotGenerateAnExternalLaunchURL() {
        XCTAssertThrowsError(try VideoPlayer.builtIn.launchURL(for: URL(string: "https://video.example/movie.mkv")!))
    }
    func testPlayersRejectUnsupportedProtocols() throws {
        for player in VideoPlayer.allCases {
            for value in ["file:///etc/passwd", "javascript:alert(1)", "ftp://video.example/file"] {
                XCTAssertThrowsError(try player.launchURL(for: URL(string: value)!))
            }
        }
    }
    func testHeaderDependentStreamCannotBypassSourceFiltering() throws {
        let source = try JSONDecoder().decode(StreamSource.self, from: Data(#"{"url":"https://source.example/video.mkv?token=a%2Fb","behaviorHints":{"proxyHeaders":{"request":{"Authorization":"Bearer private"}}}}"#.utf8))
        XCTAssertThrowsError(try StreamResolver.resolve(source)) { XCTAssertEqual($0 as? AddonError, .unsupportedStream) }
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
