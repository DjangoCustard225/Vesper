import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VesperCore

private final class IndexerRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[String: String]] = []
    func record(_ request: URLRequest) -> [String: String] {
        let query = Dictionary(
            uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value ?? "") })
        lock.lock(); values.append(query); lock.unlock(); return query
    }
    var all: [[String: String]] { lock.lock(); defer { lock.unlock() }; return values }
}
final class NZBFinderTests: XCTestCase {
    private let caps = Data(
        """
        <caps><limits max="50"/><searching><search available="yes" supportedParams="q"/><movie-search available="yes" supportedParams="q,imdbid,tmdbid"/><tv-search available="yes" supportedParams="q,tvdbid,imdbid,tmdbid,season,ep"/></searching></caps>
        """.utf8)
    private func movie() -> MediaItem {
        var item = MediaItem(id: "tt0123456", type: "movie", name: "Test Movie", poster: nil)
        item.releaseInfo = "2020"; return item
    }
    private func episode(_ number: Int = 2) throws -> Episode {
        try JSONDecoder().decode(
            Episode.self,
            from: Data(
                "{\"id\":\"custom-\(number)\",\"season\":1,\"episode\":\(number),\"released\":\"2020-01-02\"}"
                    .utf8))
    }
    private func item(_ id: String, title: String = "Test.Movie.2020.1080p", attrs: String = "") -> String {
        "<item><title>\(title)</title><guid>\(id)</guid><pubDate>Thu, 02 Jan 2020 12:00:00 +0000</pubDate><enclosure url=\"https://nzbfinder.ws/api?t=get&amp;id=\(id)&amp;apikey=secret\" length=\"123456789\"/>\(attrs)</item>"
    }
    private func rss(_ items: String, offset: Int = 0, total: Int = 1) -> Data {
        Data(
            "<rss xmlns:newznab='http://www.newznab.com/DTD/2010/feeds/attributes/'><channel><newznab:response offset='\(offset)' total='\(total)'/>\(items)</channel></rss>"
                .utf8)
    }
    func testCDATATitlesAndGUIDsAreDecodedWithoutKeepingAuthenticatedURLs() throws {
        let data = Data(
            "<rss><channel><item><title><![CDATA[Movie & Title]]></title><guid><![CDATA[release-id]]></guid></item></channel></rss>"
                .utf8)
        let document = try NewznabDocument.parse(data)
        let release = try XCTUnwrap(document.items.first?.release(context: nil, titleSearch: false))
        XCTAssertEqual(release.id, "release-id"); XCTAssertEqual(release.title, "Movie & Title")
    }
    func testAdvertisedLowerPageLimitIsRespected() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        fixture.handler = { [self] request in
            let q = requests.record(request)
            return (
                200,
                q["t"] == "caps"
                    ? Data(
                        String(decoding: caps, as: UTF8.self).replacingOccurrences(
                            of: "max=\"50\"", with: "max=\"10\""
                        ).utf8) : rss(item("one"))
            )
        }
        _ = try await NZBFinderClient(session: fixture.session()).search(
            NZBSearchContext(media: movie()), apiKey: "secret")
        XCTAssertEqual(requests.all.last?["limit"], "10")
    }
    func testGladiatorMatchesNumericIMDbWithoutPaddingAndLegacyFeedLinks() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        var media = MediaItem(id: "tt0172495", type: "movie", name: "Gladiator", poster: nil)
        media.releaseInfo = "2000"
        let response = Data(
            """
            <rss xmlns:newznab='http://www.newznab.com/DTD/2010/feeds/attributes/'><channel>
            <item><title><![CDATA[Gladiator.2000.1080p.BluRay]]></title>
            <guid isPermaLink='true'>http://www.nzbfinder.ws/details/gladiator-release</guid>
            <enclosure url='https://nzbfinder.ws/api/v1/getnzb?id=gladiator-release.nzb&amp;apikey=secret'/>
            <newznab:attr name='imdb' value='172495'/><newznab:attr name='password' value='-1'/>
            </item></channel></rss>
            """.utf8)
        fixture.handler = { [self] request in
            let q = requests.record(request)
            return (200, q["t"] == "caps" ? caps : response)
        }
        let page = try await NZBFinderClient(session: fixture.session()).search(
            NZBSearchContext(media: media), apiKey: "secret")
        XCTAssertEqual(page.releases.map(\.id), ["gladiator-release"])
        XCTAssertEqual(requests.all.last?["imdbid"], "172495")
        XCTAssertEqual(requests.all.count, 2, "Valid numeric ID results need no extra fallback query")
        XCTAssertFalse(page.releases[0].streamOption.source.nzbUrl!.contains("secret"))
    }
    func testUnknownIndexerIDsAreNotTreatedAsConflictingMetadata() throws {
        let context = try NZBSearchContext(media: movie())
        for raw in ["0", "0000000", "", "unknown"] {
            let entry = NewznabItem(title: "Test.Movie.2020", guid: "one", attributes: ["imdb": raw])
            XCTAssertNotNil(entry.release(context: context, titleSearch: false))
        }
        for raw in ["tt0123456", "0123456", "123456"] {
            let entry = NewznabItem(title: "Test.Movie.2020", guid: "one", attributes: ["imdbid": raw])
            XCTAssertNotNil(entry.release(context: context, titleSearch: false))
        }
    }
    func testReleaseReferencesAcceptTrustedFeedVariantsWithoutFollowingTheirURLs() {
        for (raw, expected) in [
            ("https://www.nzbfinder.ws/details/abc-123", "abc-123"),
            ("http://nzbfinder.ws/details/abc-123", "abc-123"),
            ("https://nzbfinder.ws/api/v1/getnzb?id=abc-123.nzb&apikey=private", "abc-123"),
            ("/getnzb/abc-123.nzb", "abc-123"),
        ] {
            XCTAssertEqual(NewznabIdentity.releaseID(raw), expected)
        }
        XCTAssertNil(NewznabIdentity.releaseID("https://nzbfinder.ws/api/v1/getnzb"))
        XCTAssertNil(NewznabIdentity.releaseID("https://attacker.test/details/abc-123"))
        let document = try? NewznabDocument.parse(
            Data(
                "<rss><channel><item><title>Release</title><link>https://nzbfinder.ws/api/v1/getnzb?id=abc-123</link></item></channel></rss>"
                    .utf8))
        XCTAssertEqual(document?.items.first?.release(context: nil, titleSearch: false)?.id, "abc-123")
    }
    func testFilteredIDResultsTriggerGenericTitleFallbackAndRecoverMistaggedRelease() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        fixture.handler = { [self] request in
            let q = requests.record(request)
            if q["t"] == "caps" { return (200, caps) }
            if q["t"] == "movie" {
                return (
                    200,
                    rss(
                        item(
                            "wrong", title: "Unrelated.2020",
                            attrs: "<newznab:attr name='imdb' value='99999'/>"))
                )
            }
            XCTAssertEqual(q["t"], "search"); XCTAssertEqual(q["q"], "Test Movie 2020")
            return (200, rss(item("right", attrs: "<newznab:attr name='imdb' value='99999'/>")))
        }
        let page = try await NZBFinderClient(session: fixture.session()).search(
            NZBSearchContext(media: movie()), apiKey: "secret")
        XCTAssertEqual(page.releases.map(\.id), ["right"])
        XCTAssertEqual(requests.all.count, 3)
    }
    func testExplicitRetryBypassesCachedEmptySearch() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        fixture.handler = { [self] request in
            let q = requests.record(request)
            if q["t"] == "caps" { return (200, caps) }
            let searchCount = requests.all.filter { $0["t"] == "search" }.count
            return (200, searchCount < 2 ? rss("", total: 0) : rss(item("new")))
        }
        let context = try NZBSearchContext(
            media: MediaItem(id: "custom", type: "movie", name: "Test Movie", poster: nil))
        let client = NZBFinderClient(session: fixture.session())
        let empty = try await client.search(context, apiKey: "secret")
        let cached = try await client.search(context, apiKey: "secret")
        XCTAssertTrue(empty.releases.isEmpty && cached.releases.isEmpty)
        XCTAssertEqual(requests.all.count, 2)
        let refreshed = try await client.search(context, apiKey: "secret", refresh: true)
        XCTAssertEqual(refreshed.releases.map(\.id), ["new"])
        XCTAssertEqual(requests.all.count, 3)
    }
    func testMovieSearchUsesIMDbAndNeverFetchesNZBOrPersistsKeyInSources() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests(),
            context = try NZBSearchContext(media: movie())
        fixture.handler = { [self] request in
            let q = requests.record(request)
            XCTAssertEqual(request.url?.host, "nzbfinder.ws"); XCTAssertEqual(request.url?.scheme, "https")
            return (200, q["t"] == "caps" ? caps : rss(item("abc123")))
        }
        let client = NZBFinderClient(session: fixture.session())
        let page = try await client.search(context, apiKey: "secret")
        XCTAssertEqual(page.releases.count, 1); XCTAssertEqual(page.releases[0].size, 123456789)
        XCTAssertNotNil(page.releases[0].posted)
        let query = try XCTUnwrap(requests.all.last)
        XCTAssertEqual(query["t"], "movie"); XCTAssertEqual(query["imdbid"], "123456");
        XCTAssertEqual(query["limit"], "50"); XCTAssertNil(query["q"])
        XCTAssertFalse(requests.all.contains { $0["t"] == "get" })
        let source = page.releases[0].streamOption
        XCTAssertEqual(source.nzbRelease?.id, "abc123")
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(source.source), as: UTF8.self).contains("secret"))
        XCTAssertThrowsError(try DownloadPolicy.url(for: source.source))
    }
    func testEpisodeSearchUsesTVDBAndExplicitCoordinatesAndRejectsPacks() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        var show = MediaItem(id: "custom-show", type: "series", name: "Test Show", poster: nil);
        show.tvdbID = 123
        let context = try NZBSearchContext(media: show, episode: episode())
        fixture.handler = { [self] request in
            let q = requests.record(request)
            return (
                200,
                q["t"] == "caps"
                    ? caps
                    : rss(
                        item("right", title: "Test.Show.S01E02.1080p")
                            + item("wrong", title: "Test.Show.S01E03")
                            + item("pack", title: "Test.Show.S01.COMPLETE")
                            + item(
                                "protected", title: "Test.Show.S01E02",
                                attrs: "<newznab:attr name='password' value='1'/>"))
            )
        }
        let page = try await NZBFinderClient(session: fixture.session()).search(context, apiKey: "secret")
        XCTAssertEqual(page.releases.map(\.id), ["right", "protected"])
        XCTAssertTrue(page.releases[1].requiresPassword)
        XCTAssertEqual(requests.all.last?["tvdbid"], "123");
        XCTAssertEqual(requests.all.last?["season"], "1"); XCTAssertEqual(requests.all.last?["ep"], "2")
        XCTAssertThrowsError(try NZBSearchContext(media: show))
    }
    func testEpisodeSearchRejectsOtherShowsAndWrongSameTitleSeriesVersion() throws {
        var show = MediaItem(id: "tt0417299", type: "series", name: "Avatar: The Last Airbender", poster: nil)
        show.releaseInfo = "2005"
        show.tvdbID = 74852
        show.tmdbID = 246
        let context = try NZBSearchContext(media: show, episode: episode())

        func release(_ title: String, _ attributes: [String: String] = [:]) -> NZBRelease? {
            NewznabItem(title: title, guid: "id", attributes: attributes)
                .release(context: context, titleSearch: false)
        }

        XCTAssertNil(release("Another.Show.S01E02.1080p"), "Episode coordinates alone cannot identify a show")
        XCTAssertNil(
            release("Avatar.The.Last.Airbender.2024.S01E02.1080p"),
            "Reject a different series with the same title")
        XCTAssertNotNil(release("Avatar.The.Last.Airbender.2005.S01E02.1080p"))
        XCTAssertNotNil(
            release("Avatar.The.Last.Airbender.S01E02.1080p"), "Keep untagged releases searchable")
        XCTAssertNotNil(release("Unrelated.Show.S01E02", ["tvdbid": "74852"]), "Trust a matching show ID")
        XCTAssertNil(
            release("Avatar.The.Last.Airbender.S01E02", ["tmdbid": "1234"]), "Reject conflicting IDs")
    }
    func testUnsupportedIDFallsBackToConstrainedQueryAndEscapesCharacters() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        var media = movie(); media.imdbID = nil
        let context = try NZBSearchContext(
            media: MediaItem(id: "custom", type: "movie", name: "Rock & Roll", poster: nil))
        fixture.handler = { [self] request in
            let q = requests.record(request)
            return (200, q["t"] == "caps" ? caps : rss(item("a", title: "Rock.and.Roll.1080p")))
        }
        _ = try await NZBFinderClient(session: fixture.session()).search(context, apiKey: "secret")
        XCTAssertEqual(requests.all.last?["q"], "Rock & Roll"); XCTAssertEqual(requests.all.count, 2)
    }
    func testEmptyIDSearchFallsBackOnceAndPaginationKeepsTitleMode() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests(),
            context = try NZBSearchContext(media: movie())
        fixture.handler = { [self] request in
            let q = requests.record(request)
            if q["t"] == "caps" { return (200, caps) }
            if q["imdbid"] != nil { return (200, rss("", total: 0)) }
            let offset = Int(q["offset"]!)!
            return (200, rss(item("release\(offset)"), offset: offset, total: 2))
        }
        let client = NZBFinderClient(session: fixture.session())
        let first = try await client.search(context, apiKey: "secret")
        XCTAssertEqual(first.next, NZBSearchCursor(offset: 1, titleSearch: true))
        let second = try await client.search(context, apiKey: "secret", cursor: first.next)
        XCTAssertNil(second.next); XCTAssertEqual(requests.all.count, 4)
        XCTAssertEqual(requests.all.last?["q"], "Test Movie 2020"); XCTAssertNil(requests.all.last?["imdbid"])
    }
    func testTitleFallbackRejectsWrongYearAndUnrelatedContent() async throws {
        let fixture = HTTPFixture(),
            context = try NZBSearchContext(
                media: MediaItem(id: "custom", type: "movie", name: "Test Movie", poster: nil))
        fixture.handler = { [self] request in
            let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            return (
                200,
                q.contains { $0.name == "t" && $0.value == "caps" }
                    ? caps : rss(item("right") + item("wrong", title: "Other.Title.2020"))
            )
        }
        let page = try await NZBFinderClient(session: fixture.session()).search(context, apiKey: "secret")
        XCTAssertEqual(page.releases.map(\.id), ["right"])
        let entry = NewznabItem(title: "Test.Movie.1999", guid: "a")
        XCTAssertNil(entry.release(context: try NZBSearchContext(media: movie()), titleSearch: true))
    }
    func testConcurrentSearchesAndRevisitsShareRequestsButDifferentKeysDoNot() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests(),
            context = try NZBSearchContext(media: movie())
        fixture.handler = { [self] request in
            let q = requests.record(request); return (200, q["t"] == "caps" ? caps : rss(item("one")))
        }
        let client = NZBFinderClient(session: fixture.session())
        async let one = client.search(context, apiKey: "first-key")
        async let two = client.search(context, apiKey: "first-key")
        _ = try await (one, two); _ = try await client.search(context, apiKey: "first-key")
        XCTAssertEqual(requests.all.count, 2)
        _ = try await client.search(context, apiKey: "second-key"); XCTAssertEqual(requests.all.count, 4)
        await client.invalidate(); _ = try await client.search(context, apiKey: "second-key");
        XCTAssertEqual(requests.all.count, 6)
    }
    func testVerifyAuthenticatesSearchWithoutConsumingNZBDownload() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        fixture.handler = { [self] request in
            let q = requests.record(request); return (200, q["t"] == "caps" ? caps : rss("", total: 0))
        }
        try await NZBFinderClient(session: fixture.session()).verify(apiKey: "secret")
        XCTAssertEqual(requests.all.map { $0["t"]! }, ["caps", "search"]);
        XCTAssertEqual(requests.all.last?["limit"], "1")
    }
    func testRetrievalUsesSelectedIDAndRejectsXMLQuotaErrorWithoutRetry() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        fixture.handler = { request in
            let q = requests.record(request)
            XCTAssertEqual(q["id"], "selected"); XCTAssertEqual(q["t"], "get")
            return (200, Data("<error code='501' description='secret private link'/>".utf8))
        }
        let client = NZBFinderClient(session: fixture.session())
        do {
            _ = try await client.nzb(NZBRelease(id: "selected", title: "Movie"), apiKey: "secret"); XCTFail()
        } catch {
            XCTAssertEqual(error as? NZBFinderError, .rateLimited);
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
        do {
            _ = try await client.nzb(NZBRelease(id: "selected", title: "Movie"), apiKey: "secret"); XCTFail()
        } catch {}
        XCTAssertEqual(requests.all.count, 1)
    }
    func testNZBRetrievalReturnsBytesAndEnforcesResponseBound() async throws {
        let fixture = HTTPFixture(), data = Data("<?xml version='1.0'?><nzb><file/></nzb>".utf8)
        fixture.handler = { _ in (200, data) }
        let client = NZBFinderClient(session: fixture.session())
        let bytes = try await client.nzb(NZBRelease(id: "one", title: "Movie"), apiKey: "secret")
        XCTAssertEqual(bytes, data)
        fixture.respond = { _ in
            FixtureResponse(status: 200, headers: ["Content-Length": "17000000"], body: Data())
        }
        do {
            _ = try await client.nzb(NZBRelease(id: "one", title: "Movie"), apiKey: "secret"); XCTFail()
        } catch { XCTAssertEqual(error as? NZBFinderError, .invalidResponse) }
    }
    func testRateLimitRespectsRetryAfterAndBlocksSearchAndRetrieval() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        fixture.respond = { [self] request in
            let q = requests.record(request)
            return q["t"] == "caps"
                ? FixtureResponse(body: caps) : FixtureResponse(status: 429, headers: ["Retry-After": "3600"])
        }
        let client = NZBFinderClient(session: fixture.session()),
            context = try NZBSearchContext(media: movie())
        for _ in 0..<2 {
            do { _ = try await client.search(context, apiKey: "secret"); XCTFail() } catch {
                XCTAssertEqual(error as? NZBFinderError, .rateLimited)
            }
        }
        XCTAssertEqual(requests.all.count, 2)
    }
    func testXMLAuthenticationErrorsAndMalformedDocumentsAreSafe() throws {
        for (code, error) in [
            (100, NZBFinderError.unauthorized), (101, .privileges), (102, .privileges), (500, .rateLimited),
            (300, .missingRelease),
        ] {
            XCTAssertThrowsError(
                try NewznabDocument.parse(Data("<error code='\(code)' description='secret'/>".utf8))
            ) {
                XCTAssertEqual($0 as? NZBFinderError, error);
                XCTAssertFalse($0.localizedDescription.contains("secret"))
            }
        }
        for data in [
            Data("<rss><channel><item>".utf8), Data("<html>login</html>".utf8),
            Data("<!DOCTYPE rss [<!ENTITY a 'x'>]><rss/>".utf8),
        ] {
            XCTAssertThrowsError(try NewznabDocument.parse(data))
        }
    }
    func testRedirectGuardAndUntrustedEnclosureCannotForwardKey() {
        XCTAssertTrue(NZBFinderRedirectGuard.permits(URL(string: "https://nzbfinder.ws/api")))
        for url in [
            "http://nzbfinder.ws/api", "https://attacker.test/api?apikey=secret",
            "https://nzbfinder.ws.attacker.test/api", "https://nzbfinder.ws:444/api",
        ] { XCTAssertFalse(NZBFinderRedirectGuard.permits(URL(string: url))) }
        let item = NewznabItem(
            title: "Movie", guid: "https://attacker.test/one", enclosure: "https://attacker.test/api?id=one")
        XCTAssertNil(item.release(context: nil, titleSearch: false))
    }
    func testMovieIDSearchRejectsUnrelatedUnidentifiedResults() throws {
        let context = try NZBSearchContext(media: movie())
        let junk = NewznabItem(title: "Unrelated.Film.2020.1080p", guid: "junk")
        let wrongYear = NewznabItem(title: "Test.Movie.2021.1080p", guid: "wrong")
        let matching = NewznabItem(title: "Test.Movie.2020.1080p", guid: "good")
        let identified = NewznabItem(
            title: "Alternative.Title.1080p", guid: "id", attributes: ["imdb": "123456"])
        XCTAssertNil(junk.release(context: context, titleSearch: false))
        XCTAssertNil(wrongYear.release(context: context, titleSearch: false))
        XCTAssertNotNil(matching.release(context: context, titleSearch: false))
        XCTAssertNotNil(identified.release(context: context, titleSearch: false))
    }
    func testSeasonPackSearchOmitsEpisodeAndKeepsCacheSeparate() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        var show = MediaItem(id: "show", type: "series", name: "Test Show")
        show.tvdbID = 123
        let regular = try NZBSearchContext(media: show, episode: episode())
        let pack = try NZBSearchContext(media: show, episode: episode(), seasonPack: true)
        fixture.handler = { [self] request in
            let q = requests.record(request)
            if q["t"] == "caps" { return (200, caps) }
            if q["ep"] != nil { return (200, rss(item("episode", title: "Test.Show.S01E02"))) }
            return (
                200,
                rss(
                    item(
                        "pack", title: "Test.Show.S01.COMPLETE",
                        attrs:
                            "<newznab:attr name='season' value='1'/><newznab:attr name='episode' value='0'/><newznab:attr name='password' value='1'/>"
                    )
                        + item(
                            "single", title: "Test.Show.S01E03",
                            attrs:
                                "<newznab:attr name='season' value='1'/><newznab:attr name='episode' value='0'/>"
                        )
                        + item("other", title: "Test.Show.S02.COMPLETE")
                )
            )
        }
        let client = NZBFinderClient(session: fixture.session())
        let first = try await client.search(regular, apiKey: "secret")
        let second = try await client.search(pack, apiKey: "secret")
        XCTAssertEqual(first.releases.map(\.id), ["episode"])
        XCTAssertEqual(second.releases.map(\.id), ["pack"])
        XCTAssertTrue(second.releases[0].isSeasonPack && second.releases[0].requiresPassword)
        XCTAssertTrue(second.releases[0].streamOption.source.description?.contains("Season pack") == true)
        XCTAssertEqual(requests.all.last?["season"], "1")
        XCTAssertNil(requests.all.last?["ep"])
        XCTAssertEqual(requests.all.last?["tvdbid"], "123")
        _ = try await client.search(pack, apiKey: "secret")
        XCTAssertEqual(requests.all.count, 3)
    }
    func testSeasonPackFallbackQueryAndStrictTitleMatching() throws {
        let show = MediaItem(id: "show", type: "series", name: "Test Show")
        let context = try NZBSearchContext(media: show, episode: episode(), seasonPack: true)
        let caps = NewznabCapabilities(search: ["q"])
        let query = try caps.query(context, titleOnly: true)
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "Test Show S01")
        for title in ["Test.Show.S01.COMPLETE.1080p", "Test.Show.Season.1.1080p"] {
            XCTAssertNotNil(
                NewznabItem(title: title, guid: "pack").release(context: context, titleSearch: true))
        }
        for title in [
            "Other.Show.S01.COMPLETE", "Test.Show.S01E02", "Test.Show.1x02", "Test.Show.S02.COMPLETE",
            "Test.Show.S010.COMPLETE",
        ] {
            XCTAssertNil(
                NewznabItem(title: title, guid: "pack").release(context: context, titleSearch: true), title)
        }
    }
    func testDownloadPreservesResponsePasswordWithoutAttachingItToRelease() async throws {
        let fixture = HTTPFixture(), requests = IndexerRequests()
        fixture.respond = { request in
            let q = requests.record(request)
            XCTAssertEqual(q["t"], "get")
            return FixtureResponse(headers: ["x-dnzb-password": "archive-secret"], body: Data("<nzb/>".utf8))
        }
        let release = NZBRelease(id: "one", title: "One", requiresPassword: true)
        let download = try await NZBFinderClient(session: fixture.session()).download(
            release, apiKey: "api-secret")
        XCTAssertEqual(download.password, "archive-secret")
        XCTAssertEqual(requests.all.count, 1)
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(release.streamOption.source), as: UTF8.self).contains(
                "archive-secret"))
    }
    @MainActor func testFilteredOutPagesAdvanceUntilMatchesAndPreserveCursorOnError() async {
        let model = NZBFinderSearchController()
        var offsets: [Int] = []
        await model.load { cursor in
            let offset = cursor?.offset ?? 0
            offsets.append(offset)
            return NZBSearchPage(
                releases: offset == 2 ? [NZBRelease(id: "pack", title: "Pack")] : [],
                next: offset < 2 ? NZBSearchCursor(offset: offset + 1, titleSearch: true) : nil)
        }
        XCTAssertEqual(offsets, [0, 1, 2])
        XCTAssertEqual(model.releases.map(\.id), ["pack"])
        XCTAssertNil(model.next)
        await model.load { cursor in
            if cursor != nil { throw NZBFinderError.rateLimited }
            return NZBSearchPage(releases: [], next: NZBSearchCursor(offset: 1, titleSearch: true))
        }
        XCTAssertEqual(model.error, NZBFinderError.rateLimited.localizedDescription)
        XCTAssertEqual(model.next?.offset, 1)
    }
    @MainActor func testPaginationDeduplicatesStopsRepeatsAndKeepsResultsOnFailure() async {
        let model = NZBFinderSearchController()
        var fail = true
        await model.load { cursor in
            if cursor == nil {
                return NZBSearchPage(
                    releases: [NZBRelease(id: "one", title: "One")],
                    next: NZBSearchCursor(offset: 1, titleSearch: false))
            }
            if fail { throw NZBFinderError.unavailable }
            return NZBSearchPage(
                releases: [NZBRelease(id: "one", title: "One")],
                next: NZBSearchCursor(offset: 2, titleSearch: false))
        }
        await model.loadNext(); XCTAssertEqual(model.releases.count, 1); XCTAssertNotNil(model.error);
        XCTAssertNotNil(model.next)
        fail = false; await model.loadNext(); XCTAssertNil(model.next); XCTAssertNil(model.error)
    }
    @MainActor func testLateSearchCannotOverwriteReplacement() async throws {
        let model = NZBFinderSearchController()
        let old = Task {
            await model.load { _ in
                try? await Task.sleep(for: .milliseconds(100));
                return NZBSearchPage(releases: [NZBRelease(id: "old", title: "Old")])
            }
        }
        while !model.loading { await Task.yield() }
        await model.load { _ in NZBSearchPage(releases: [NZBRelease(id: "new", title: "New")]) }
        await old.value; XCTAssertEqual(model.releases.map(\.id), ["new"])
    }
}
