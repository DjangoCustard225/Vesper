import XCTest
@testable import VesperCore

final class CatalogPreferencesTests: XCTestCase {
    private func addon(_ host: String = "first.example", enabled: Bool = true) throws -> InstalledAddon {
        let manifest = try JSONDecoder().decode(
            AddonManifest.self,
            from: Data(
                #"{"id":"provider","name":"Provider","version":"1","resources":["catalog","stream"],"types":["movie","series"],"catalogs":[{"id":"popular","type":"movie","name":"Movies","extra":[{"name":"genre","options":["Drama","Comedy"]},{"name":"sort","options":["Popular","Recent"]}]},{"id":"popular","type":"series","name":"Shows"},{"id":"search","type":"movie","extra":[{"name":"search","isRequired":true}]}]}"#
                    .utf8))
        return InstalledAddon(
            manifestURL: try XCTUnwrap(URL(string: "https://\(host)/private/manifest.json")),
            manifest: manifest, isEnabled: enabled)
    }

    private func filterCatalog(_ json: String) throws -> AddonCatalog {
        try JSONDecoder().decode(AddonCatalog.self, from: Data(json.utf8))
    }

    func testDefaultsPreserveExistingLayoutAndExcludeSearchOnlyCatalogs() throws {
        let catalogs = HomeCatalog.catalogs(addons: [try addon()], includeTMDB: true)
        let preferences = CatalogPreferences()
        XCTAssertEqual(catalogs.count, TMDBCatalog.allCases.count + 2)
        XCTAssertEqual(preferences.ordered(catalogs).map(\.id), catalogs.map(\.id))
        XCTAssertEqual(preferences.requested(catalogs, heroID: "automatic").map(\.id), catalogs.map(\.id))
        XCTAssertTrue(preferences.customizations.isEmpty)
    }

    func testCustomOrderMixesProvidersAndAppendsNewCatalogsWithoutDuplicateIDs() throws {
        let original = HomeCatalog.catalogs(addons: [try addon()], includeTMDB: true)
        let first = try XCTUnwrap(original.last)
        let preferences = CatalogPreferences(order: [first.id, "removed", original[0].id, first.id])
        let current =
            original + HomeCatalog.catalogs(addons: [try addon("second.example")], includeTMDB: false)
        let ordered = preferences.ordered(current + [first]).map(\.id)
        XCTAssertEqual(
            ordered,
            [first.id, original[0].id]
                + current.filter { $0.id != first.id && $0.id != original[0].id }.map(\.id))
        XCTAssertEqual(Set(ordered).count, current.count)
    }

    func testCatalogIdentitySeparatesInstallationsAndMediaTypesAndPreservesHeroIDs() throws {
        let catalogs = HomeCatalog.catalogs(
            addons: [try addon(), try addon("second.example")], includeTMDB: true)
        XCTAssertEqual(Set(catalogs.map(\.id)).count, catalogs.count)
        XCTAssertEqual(catalogs.first?.id, "tmdb:popularMovies")
        if case .addon(let feed) = catalogs[4] {
            XCTAssertEqual(catalogs[4].id, "addon:" + feed.addon.id + ":movie:popular")
        } else {
            XCTFail("Missing add-on catalog")
        }
    }

    func testHiddenRowsStayAvailableForExplicitHeroSelection() throws {
        let catalogs = HomeCatalog.catalogs(addons: [try addon()], includeTMDB: false)
        let hidden = try XCTUnwrap(catalogs.first)
        let preferences = CatalogPreferences(customizations: [hidden.id: .init(isHidden: true)])
        XCTAssertEqual(preferences.requested(catalogs, heroID: "automatic").map(\.id), [catalogs[1].id])
        XCTAssertEqual(preferences.requested(catalogs, heroID: hidden.id).map(\.id), catalogs.map(\.id))
        if case .addon(let feed) = hidden {
            XCTAssertTrue(feed.addon.isEnabled)
            XCTAssertTrue(feed.addon.manifest.supports("stream", type: "movie", id: "tt123"))
        }
    }

    func testDisabledAddonMakesNoRequestsAndRetainsItsCustomizations() throws {
        let enabled = HomeCatalog.catalogs(addons: [try addon()], includeTMDB: false)
        let disabled = HomeCatalog.catalogs(addons: [try addon(enabled: false)], includeTMDB: false)
        let id = try XCTUnwrap(enabled.first?.id)
        let preferences = CatalogPreferences(
            order: [id], customizations: [id: .init(name: "My movies", filters: ["genre": "Drama"])])
        XCTAssertTrue(preferences.requested(disabled, heroID: id).isEmpty)
        XCTAssertEqual(preferences.title(for: enabled[0]), "My movies")
        XCTAssertEqual(preferences.extras(for: enabled[0]), ["genre": "Drama"])
    }

    func testPresentationEditsKeepRequestSignaturesWhileFiltersAndVisibilityChangeThem() throws {
        let catalogs = HomeCatalog.catalogs(addons: [try addon()], includeTMDB: true)
        let catalog = try XCTUnwrap(catalogs.last)
        let defaults = CatalogPreferences().requests(catalogs, heroID: "automatic")
        var preferences = CatalogPreferences(
            order: catalogs.reversed().map(\.id), customizations: [catalog.id: .init(name: "Favorites")])
        XCTAssertEqual(preferences.requests(catalogs, heroID: "automatic"), defaults)
        preferences.customizations[catalog.id]?.isHidden = true
        XCTAssertNotEqual(preferences.requests(catalogs, heroID: "automatic"), defaults)
        let movies = catalogs[4]
        preferences = CatalogPreferences(customizations: [movies.id: .init(filters: ["genre": "Comedy"])])
        XCTAssertNotEqual(preferences.requests(catalogs, heroID: "automatic"), defaults)
    }

    func testOnlyAdvertisedChoicesAreEditableAndManagedExtrasCannotBeOverridden() throws {
        let catalog = try filterCatalog(
            #"{"id":"filter","type":"movie","extra":[{"name":"search","options":["ignored"]},{"name":"skip","isRequired":true},{"name":"genre","options":["Drama","Comedy","Drama",""]},{"name":"sort","options":["Top","Recent"],"isRequired":true},{"name":"language"}]}"#
        )
        XCTAssertEqual(catalog.filters.map(\.id), ["genre", "sort"])
        XCTAssertEqual(catalog.filters[0].options, ["Drama", "Comedy"])
        XCTAssertEqual(
            catalog.effectiveExtras([
                "genre": "Comedy", "sort": "Recent", "search": "ignored", "skip": "999", "language": "en",
            ]), ["genre": "Comedy", "sort": "Recent", "skip": "0"])
        XCTAssertEqual(
            catalog.effectiveExtras(["genre": "removed", "sort": "removed"]), ["sort": "Top", "skip": "0"])
        XCTAssertEqual(catalog.effectiveExtras(["genre": "", "sort": ""]), ["sort": "Top", "skip": "0"])
    }

    func testLegacyGenresAndRequiredYearChoicesKeepTheirDefaults() throws {
        let legacy = try filterCatalog(
            #"{"id":"legacy","type":"series","genres":["Drama"],"extraRequired":["genre"],"extraSupported":["genre"]}"#
        )
        XCTAssertEqual(legacy.filters.first?.title, "Genre")
        XCTAssertEqual(legacy.effectiveExtras([:]), ["genre": "Drama"])
        let years = try filterCatalog(
            #"{"id":"years","type":"movie","extra":[{"name":"genre","isRequired":true,"options":["2026","2025"]}]}"#
        )
        XCTAssertEqual(years.filters.first?.title, "Year")
        XCTAssertEqual(years.effectiveExtras(["genre": "removed"]), ["genre": "2026"])
        XCTAssertTrue(years.canRequest(with: years.effectiveExtras([:])))
    }

    func testFiltersUseExistingRequestEncodingAndSeparateCacheKeys() throws {
        let provider = try addon()
        let catalog = try XCTUnwrap(provider.manifest.catalogs.first)
        let first = catalog.effectiveExtras(["genre": "Drama"])
        let second = catalog.effectiveExtras(["genre": "Comedy"])
        XCTAssertNotEqual(
            try MetadataCacheKey.addonCatalog(provider, catalog, extras: first),
            try MetadataCacheKey.addonCatalog(provider, catalog, extras: second))
        let url = try AddonURL.resource(
            manifest: provider.manifestURL, resource: "catalog", type: catalog.type, id: catalog.id,
            extras: ["genre": "雪 & +/", "skip": "20"])
        XCTAssertTrue(url.absoluteString.contains("genre=%E9%9B%AA%20%26%20%2B%2F&skip=20.json"))
    }

    func testPersistenceAndResetsKeepSettingsIndependentFromInstalledAddons() throws {
        let catalogs = HomeCatalog.catalogs(addons: [try addon()], includeTMDB: true)
        let catalog = try XCTUnwrap(catalogs.last)
        var preferences = CatalogPreferences(
            order: catalogs.reversed().map(\.id),
            customizations: [
                catalog.id: .init(isHidden: true, name: "  Favorites  ", filters: ["sort": "Recent"])
            ])
        let stored = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(CatalogPreferences.self, from: stored), preferences)
        XCTAssertEqual(preferences.title(for: catalog), "Favorites")
        preferences.customizations[catalog.id] = .init(name: " \n ")
        XCTAssertEqual(preferences.title(for: catalog), catalog.title)
        preferences.customizations[catalog.id] = nil
        XCTAssertFalse(preferences.customization(for: catalog.id).isHidden)
        preferences = CatalogPreferences()
        XCTAssertEqual(preferences.ordered(catalogs).map(\.id), catalogs.map(\.id))
    }
    func testCombinedMembersKeepFiltersAndShareRequestsWithExplicitHero() throws {
        let sources = HomeCatalog.catalogs(addons: [try addon()], includeTMDB: true)
        let movie = sources[4]
        let group = CombinedCatalog(name: "Mixed", members: [movie.id, sources[0].id])
        let catalogs = sources + [.combined(group)]
        var preferences = CatalogPreferences(
            customizations: [movie.id: .init(isHidden: true, filters: ["genre": "Drama"])], groups: [group])
        let requests = preferences.requests(catalogs, heroID: movie.id)
        XCTAssertEqual(requests[movie.id], ["genre": "Drama"])
        XCTAssertEqual(requests.count, sources.count)
        preferences.groups[0].name = "Renamed"
        preferences.groups[0].members.reverse()
        XCTAssertEqual(
            preferences.requests(sources + preferences.groups.map(HomeCatalog.combined), heroID: movie.id),
            requests)
        preferences.customizations[movie.id]?.filters["genre"] = "Comedy"
        XCTAssertNotEqual(preferences.requests(catalogs, heroID: movie.id), requests)
    }

}
