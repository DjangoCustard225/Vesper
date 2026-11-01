import VesperCore

extension AppStore {
    var catalogs: [HomeCatalog] { catalogPresentation.catalogs }
    var availableCatalogs: [HomeCatalog] { catalogPresentation.availableCatalogs }
    var homeRows: [HomeCatalogRow] { catalogPresentation.rows }

    func catalogTitle(_ catalog: HomeCatalog) -> String { catalogPreferences.title(for: catalog) }

    func catalogDefaults(_ feed: CatalogFeed) -> [String: String] {
        catalogPreferences.extras(for: .addon(feed))
    }

    func catalogSource(_ catalog: HomeCatalog) -> ContentSource? {
        switch catalog {
        case .addon(let feed): addonSource(feed)
        case .tmdb(let value): tmdbSource(value)
        case .combined: nil
        }
    }

    func combinedSources(_ group: CombinedCatalog) -> [CombinedCatalogSource] {
        catalogPreferences.members(of: group, in: availableCatalogs).compactMap { catalog in
            guard let source = catalogSource(catalog) else { return nil }
            return CombinedCatalogSource(id: catalog.id, title: catalogTitle(catalog), source: source)
        }
    }
}
