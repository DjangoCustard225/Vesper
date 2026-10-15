import XCTest
@testable import VesperCore

@MainActor
final class StreamDiscoveryTests: XCTestCase {
    private func provider(_ name: String, enabled: Bool = true, resources: String = "stream") throws
        -> InstalledAddon
    {
        let data = Data(
            """
            {"id":"\(name)","name":"\(name)","version":"1","resources":["\(resources)"],"types":["movie"],"catalogs":[]}
            """.utf8)
        return InstalledAddon(
            manifestURL: try XCTUnwrap(URL(string: "https://\(name).example/manifest.json")),
            manifest: try JSONDecoder().decode(AddonManifest.self, from: data), isEnabled: enabled)
    }

    func testProviderOrderDeduplicationAndPartialDelivery() async throws {
        let fixture = HTTPFixture()
        let firstMayFinish = DispatchSemaphore(value: 0)
        fixture.handler = { request in
            let name = request.url?.host?.components(separatedBy: ".").first ?? ""
            if name == "first" { XCTAssertEqual(firstMayFinish.wait(timeout: .now() + 2), .success) }
            let body = Data(
                """
                {"streams":[{"url":"https://video.example/shared.mkv"},{"url":"https://video.example/\(name).mkv"}]}
                """.utf8)
            return (200, body)
        }
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        let discovery = StreamDiscovery(client: AddonClient(session: session))
        var updates: [StreamResults] = []
        let result = await discovery.load(
            addons: [try provider("first"), try provider("second")],
            type: "movie", videoID: "tt1"
        ) { partial in
            updates.append(partial)
            firstMayFinish.signal()
        }
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.first?.options.first?.addonName, "second")
        XCTAssertEqual(result.options.map(\.addonName), ["first", "first", "second"])
        XCTAssertEqual(result.options.first?.provider?.manifest.name, "first")
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(updates.last?.options.map(\.id), result.options.map(\.id))
    }

    func testFailedProviderDoesNotHideWorkingSources() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { request in
            if request.url?.host == "broken.example" { return (503, Data()) }
            return (200, Data(#"{"streams":[{"url":"https://video.example/movie.mkv"}]}"#.utf8))
        }
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        let discovery = StreamDiscovery(
            client: AddonClient(session: session, retryPolicy: RetryPolicy(attempts: 1)))
        let result = await discovery.load(
            addons: [try provider("broken"), try provider("working")],
            type: "movie", videoID: "tt1")
        XCTAssertEqual(result.options.map(\.addonName), ["working"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures.first?.hasPrefix("broken: ") == true)
    }

    func testEmbeddedSourcesBypassProvidersAndStillFilterUnsupportedSources() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { _ in
            XCTFail("Embedded sources must not contact providers")
            return (500, Data())
        }
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        let sources = try JSONDecoder().decode(
            [StreamSource].self,
            from: Data(#"[{"url":"https://video.example/movie.mkv"},{"infoHash":"torrent"}]"#.utf8))
        let result = await StreamDiscovery(client: AddonClient(session: session))
            .load(addons: [try provider("unused")], type: "movie", videoID: "tt1", embedded: sources)
        XCTAssertEqual(result.options.count, 1)
        XCTAssertEqual(result.options.first?.addonName, "Included source")
        XCTAssertEqual(result.failures.count, 1)
    }

    func testDisabledAndUnsupportedProvidersAreSkipped() async throws {
        let fixture = HTTPFixture()
        fixture.handler = { _ in
            XCTFail("Ineligible provider contacted")
            return (500, Data())
        }
        let session = fixture.session()
        defer { session.invalidateAndCancel() }
        let providers = try [provider("disabled", enabled: false), provider("catalog", resources: "catalog")]
        let result = await StreamDiscovery(client: AddonClient(session: session))
            .load(addons: providers, type: "movie", videoID: "tt1")
        XCTAssertTrue(result.options.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
    }
}
