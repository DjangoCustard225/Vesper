import Foundation
import VesperCore

extension AppStore {
    func addonSource(_ feed: CatalogFeed, genre: String? = nil, search: String? = nil) -> ContentSource {
        let client = client
        var base = feed.catalog.defaultExtras
        if let genre, !genre.isEmpty { base["genre"] = genre }
        if let search { base["search"] = search }
        let extras = base
        return ContentSource(id: MetadataCacheKey.id(feed.id), title: feed.addon.manifest.name, initialCursor: 0) { cursor in
            var values = extras
            if cursor > 0 { values["skip"] = String(cursor) }
            let key = try MetadataCacheKey.addonCatalog(feed.addon, feed.catalog, extras: values)
            let next = try await client.catalog(feed.addon, feed.catalog, extras: values)
            let items = search == nil ? await self.identifiedItems(next, resolveUnknown: false) : next
            return ContentPage(items: items, nextCursor: search == nil && feed.catalog.supports("skip") && !next.isEmpty ? cursor + next.count : nil,
                               cacheID: MetadataCacheKey.id(key))
        }
    }
    func tmdbSource(_ catalog: TMDBCatalog) -> ContentSource {
        let credential = tmdbCredential, revision = tmdbRevision
        return ContentSource(id: catalog.id, title: "TMDB") { cursor in
            guard let credential, self.tmdbRevision == revision else { throw CancellationError() }
            let result = try await self.tmdbCatalog(catalog, page: cursor)
            let key = try MetadataCacheKey.catalog(catalog, page: cursor, credential: credential)
            return ContentPage(items: result.items, nextCursor: result.hasMore ? cursor + 1 : nil, cacheID: MetadataCacheKey.id(key))
        }
    }
    func searchSources(_ term: String) -> [ContentSource] {
        var sources: [ContentSource] = []
        if let credential = tmdbCredential {
            let revision = tmdbRevision
            sources.append(ContentSource(id: "tmdb-search", title: "TMDB", allowEmptyPages: true) { cursor in
                guard self.tmdbRevision == revision else { throw CancellationError() }
                let result = try await self.tmdbSearch(term, page: cursor)
                let key = try MetadataCacheKey.search(term, page: cursor, credential: credential)
                return ContentPage(items: result.items, nextCursor: result.hasMore ? cursor + 1 : nil, cacheID: MetadataCacheKey.id(key))
            })
        }
        sources += enabledAddons.flatMap { addon in
            addon.manifest.catalogs.filter {
                $0.supports("search") && $0.canRequest(with: $0.defaultExtras.merging(["search": term]) { _, new in new })
            }.map { addonSource(CatalogFeed(addon: addon, catalog: $0), search: term) }
        }
        return sources
    }
    func relatedSource(_ details: TMDBEnrichment) -> ContentSource {
        let credential = tmdbCredential, revision = tmdbRevision
        return ContentSource(id: "\(details.mediaType):\(details.id)", title: "TMDB") { cursor in
            guard let credential, self.tmdbRevision == revision else { throw CancellationError() }
            let result = try await self.recommendations(for: details, page: cursor)
            let key = try MetadataCacheKey.recommendations(id: details.id, type: details.mediaType, page: cursor, credential: credential)
            return ContentPage(items: result.items, cacheID: MetadataCacheKey.id(key))
        }
    }
    func detailsCacheID(_ item: MediaItem) -> String? {
        tmdbCredential.map { MetadataCacheKey.id(MetadataCacheKey.details(item, credential: $0)) }
    }
    func episodesCacheID(_ item: MediaItem, details: TMDBEnrichment?, season: Int?) -> String? {
        guard let credential = tmdbCredential, let details, let season else { return nil }
        return MetadataCacheKey.id(MetadataCacheKey.episodes(item, id: details.id, season: season, credential: credential))
    }
}
