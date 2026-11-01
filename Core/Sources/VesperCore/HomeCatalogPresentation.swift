import Foundation

public struct HomeCatalogRow: Identifiable, Sendable {
    public let catalog: HomeCatalog
    public let title: String
    public let items: [MediaItem]
    public let error: String?
    public let isLoading: Bool
    public let isUnavailable: Bool
    public var id: String { catalog.id }
}

/// An immutable projection built when feed data or preferences change, never for scroll positions.
public struct HomeCatalogPresentation: Sendable {
    public let catalogs: [HomeCatalog]
    public let availableCatalogs: [HomeCatalog]
    public let rows: [HomeCatalogRow]
    public let prefetchRows: [ArtworkPrefetchWindow.Row]
    public let heroCatalogs: [HeroCatalog]
    public let heroItems: [MediaItem]

    public init(
        addons: [InstalledAddon], tmdbConfigured: Bool, preferences: CatalogPreferences,
        feeds: [CatalogFeed], tmdbFeeds: [TMDBFeed], settledCatalogIDs: Set<String>,
        isLoading: Bool, heroID: String
    ) {
        catalogs = preferences.ordered(
            HomeCatalog.catalogs(addons: addons, includeTMDB: true)
                + preferences.groups.map(HomeCatalog.combined))
        availableCatalogs = catalogs.filter {
            switch $0 {
            case .combined: true
            case .tmdb: tmdbConfigured
            case .addon(let feed): feed.addon.isEnabled
            }
        }
        var sourceItems: [String: [MediaItem]] = [:]
        var sourceErrors: [String: String] = [:]
        for feed in feeds {
            let id = "addon:" + feed.id
            sourceItems[id] = feed.items
            sourceErrors[id] = feed.error
        }
        for feed in tmdbFeeds where tmdbConfigured {
            let id = "tmdb:" + feed.id
            sourceItems[id] = feed.items
            sourceErrors[id] = feed.error
        }
        let availableSources = Dictionary(
            uniqueKeysWithValues: availableCatalogs.compactMap { catalog -> (String, HomeCatalog)? in
                if case .combined = catalog { return nil }
                return (catalog.id, catalog)
            })
        var projected: [HomeCatalogRow] = []
        for catalog in availableCatalogs {
            let members: [String]
            let items: [MediaItem]
            if case .combined(let group) = catalog {
                members = group.members.filter { availableSources[$0] != nil }
                items =
                    members.allSatisfy(settledCatalogIDs.contains)
                    ? CombinedCatalog.alternating(members.map { sourceItems[$0] ?? [] }) : []
            } else {
                members = [catalog.id]
                items = MediaIdentity.unique(sourceItems[catalog.id] ?? [])
            }
            let errors = members.compactMap { sourceErrors[$0] }
            projected.append(
                HomeCatalogRow(
                    catalog: catalog, title: preferences.title(for: catalog),
                    items: Array(items.prefix(20)),
                    error: errors.isEmpty ? nil : errors.joined(separator: "\n"),
                    isLoading: isLoading && members.contains { !settledCatalogIDs.contains($0) },
                    isUnavailable: members.isEmpty))
        }
        rows = projected.filter { preferences.isVisible($0.catalog) }
        prefetchRows = rows.map { .init(id: $0.id, items: $0.items) }
        heroCatalogs = projected.map {
            HeroCatalog(id: $0.id, title: $0.catalog.providerName + " · " + $0.title, items: $0.items)
        }
        let visibleIDs = Set(rows.map(\.id))
        heroItems = HeroCatalogSelection.items(
            preferredID: heroID,
            catalogs: heroCatalogs.filter { visibleIDs.contains($0.id) || $0.id == heroID })
    }
}
