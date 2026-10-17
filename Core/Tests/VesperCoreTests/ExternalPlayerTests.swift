import XCTest
@testable import VesperCore

final class ExternalPlayerTests: XCTestCase {
    func testPlayerURLsPreserveSignedNestedStreamURLs() throws {
        let stream = URL(
            string: "https://video.example/雪%20movie.mkv?token=a%2Fb+q&expires=42&sign=x%3Dy#fragment")!
        for player in VideoPlayer.externalPlayers where player.detectionURL != nil {
            let launch = try player.launchURL(for: stream)
            let components = try XCTUnwrap(URLComponents(url: launch, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, player.detectionURL?.scheme)
            XCTAssertEqual(components.host, "x-callback-url")
            XCTAssertEqual(components.path, player == .vlc ? "/stream" : "/play")
            XCTAssertEqual(components.queryItems?.first { $0.name == "url" }?.value, stream.absoluteString)
            XCTAssertEqual(components.queryItems?.map(\.name), ["url"])
        }
    }

    func testSavedPlayerMigrationRetainsExternalChoices() {
        XCTAssertEqual(VideoPlayer.preferred(storedValue: "vlc"), .vlc)
        XCTAssertEqual(VideoPlayer.preferred(storedValue: "infuse"), .infuse)
        for value in [nil, "builtIn", "unknown", "vidhub", "other"] {
            XCTAssertEqual(VideoPlayer.preferred(storedValue: value), .builtIn)
        }
        XCTAssertEqual(VideoPlayer.preferred(storedValue: "aether"), .aether)
        XCTAssertEqual(VideoPlayer.allCases, [.builtIn, .aether, .vlc, .infuse, .outplayer])
        XCTAssertEqual(VideoPlayer.externalPlayers, [.vlc, .infuse, .outplayer])
    }

    func testBuiltInPlayerDoesNotGenerateAnExternalLaunchURL() {
        for player in VideoPlayer.allCases {
            XCTAssertEqual(player.isInternal, !VideoPlayer.externalPlayers.contains(player))
            if player.isInternal {
                XCTAssertThrowsError(
                    try player.launchURL(for: URL(string: "https://video.example/movie.mkv")!))
            }
        }
    }

    func testDiscoveryQueriesOnlyRegisteredPlayersAndPreservesBuiltInChoices() {
        var schemes: [String] = []
        let available = VideoPlayer.availablePlayers(VideoPlayer.allCases) { url in
            schemes.append(url.scheme!)
            return url.scheme == "outplayer"
        }
        XCTAssertEqual(schemes, ["vlc-x-callback", "infuse", "outplayer"])
        XCTAssertEqual(available, [.builtIn, .aether, .outplayer])
        XCTAssertEqual(VideoPlayer.builtIn.availablePreference(in: available), .builtIn)
        XCTAssertEqual(VideoPlayer.infuse.availablePreference(in: available), .outplayer)
    }

    func testNoInstalledExternalPlayersPreservesSavedChoiceForReinstallation() {
        let available = VideoPlayer.availablePlayers(VideoPlayer.externalPlayers) { _ in false }
        XCTAssertTrue(available.isEmpty)
        XCTAssertEqual(VideoPlayer.outplayer.availablePreference(in: available), .outplayer)
        let restored = VideoPlayer.availablePlayers(VideoPlayer.externalPlayers) { $0.scheme == "outplayer" }
        XCTAssertEqual(VideoPlayer.outplayer.availablePreference(in: restored), .outplayer)
    }

    func testManualSelectionBypassesUnavailableSchemeQueriesAndPreservesPreference() throws {
        let available = VideoPlayer.availablePlayers(
            VideoPlayer.allCases, showAllExternalPlayers: true
        ) { _ in
            XCTFail("Manual selection must not query the container host for installed players")
            return false
        }
        XCTAssertEqual(available, VideoPlayer.allCases)
        let stream = URL(string: "https://video.example/movie.mkv")!
        for player in VideoPlayer.externalPlayers {
            XCTAssertEqual(player.availablePreference(in: available), player)
            XCTAssertNoThrow(try player.launchURL(for: stream))
        }
        let detected = VideoPlayer.availablePlayers(VideoPlayer.allCases) { _ in false }
        XCTAssertEqual(detected, [.builtIn, .aether])
    }

    func testInstalledPreferenceSurvivesRescansAndRemovedAppsGetAvailableFallback() {
        let available = VideoPlayer.availablePlayers(VideoPlayer.externalPlayers) { _ in true }
        XCTAssertEqual(VideoPlayer.outplayer.availablePreference(in: available), .outplayer)
        XCTAssertEqual(VideoPlayer.vlc.availablePreference(in: [.infuse]), .infuse)
        XCTAssertEqual(VideoPlayer.vlc.availablePreference(in: [.builtIn, .aether]), .builtIn)
    }

    func testOutplayerIsDetectedAndRetainedAsPreferredPlayer() {
        let available = VideoPlayer.availablePlayers(VideoPlayer.externalPlayers) { $0.scheme == "outplayer" }
        XCTAssertEqual(available, [.outplayer])
        XCTAssertEqual(VideoPlayer.outplayer.detectionURL?.absoluteString, "outplayer://x-callback-url/play")
        XCTAssertEqual(
            VideoPlayer.preferred(storedValue: "outplayer").availablePreference(in: available), .outplayer)
        XCTAssertEqual(VideoPlayer.infuse.availablePreference(in: available), .outplayer)
    }

    func testPlayersRejectUnsupportedProtocols() throws {
        for player in VideoPlayer.allCases {
            for value in ["file:///etc/passwd", "javascript:alert(1)", "ftp://video.example/file"] {
                XCTAssertThrowsError(try player.launchURL(for: URL(string: value)!))
            }
        }
    }

    func testHeaderDependentStreamCannotBypassSourceFiltering() throws {
        let source = try JSONDecoder().decode(
            StreamSource.self,
            from: Data(
                #"{"url":"https://source.example/video.mkv?token=a%2Fb","behaviorHints":{"proxyHeaders":{"request":{"Authorization":"Bearer private"}}}}"#
                    .utf8))
        XCTAssertThrowsError(try StreamResolver.resolve(source)) {
            XCTAssertEqual($0 as? AddonError, .unsupportedStream)
        }
    }

    func testCinemetaMigrationKeepsOtherAddons() throws {
        func addon(_ id: String, host: String) throws -> InstalledAddon {
            let manifest = try JSONDecoder().decode(
                AddonManifest.self,
                from: Data(
                    """
                    {"id":"\(id)","name":"Provider","version":"1.0","resources":["stream"],"types":["movie"],"catalogs":[]}
                    """.utf8))
            return InstalledAddon(
                manifestURL: URL(string: "https://\(host)/manifest.json")!, manifest: manifest)
        }
        let saved = try [
            addon("com.linvo.cinemeta", host: "mirror.example"), addon("other", host: "v3-cinemeta.strem.io"),
            addon("my.streams", host: "streams.example"),
        ]
        XCTAssertEqual(saved.filter { !AddonPolicy.isCinemeta($0) }.map(\.manifest.id), ["my.streams"])
    }
}
