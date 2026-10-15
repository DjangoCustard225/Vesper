import Foundation
import VesperCore

extension AppStore {
    func filmographyCacheID(_ id: Int) -> String? {
        tmdbCredential.map { MetadataCacheKey.id(MetadataCacheKey.personFilmography(id, credential: $0)) }
    }

    func addonSource(_ feed: CatalogFeed, genre: String? = nil) -> ContentSource {
        let client = client
        var base = feed.catalog.defaultExtras
        if let genre, !genre.isEmpty { base["genre"] = genre }
        let extras = base
        let initialCacheID = (try? MetadataCacheKey.addonCatalog(feed.addon, feed.catalog, extras: extras))
            .map(MetadataCacheKey.id)
        return ContentSource(initialCursor: 0, initialCacheID: initialCacheID) { cursor in
            var values = extras
            if cursor > 0 { values["skip"] = String(cursor) }
            let key = try MetadataCacheKey.addonCatalog(feed.addon, feed.catalog, extras: values)
            let next = try await client.catalog(feed.addon, feed.catalog, extras: values)
            let items = await self.identifiedItems(next, resolveUnknown: false)
            return ContentPage(
                items: items,
                nextCursor: feed.catalog.supports("skip") && !next.isEmpty ? cursor + next.count : nil,
                cacheID: MetadataCacheKey.id(key))
        }
    }

    func tmdbSource(_ catalog: TMDBCatalog) -> ContentSource {
        let credential = tmdbCredential, revision = tmdbRevision
        let initialCacheID = credential.flatMap {
            try? MetadataCacheKey.catalog(catalog, page: 1, credential: $0)
        }
        .map(MetadataCacheKey.id)
        return ContentSource(initialCacheID: initialCacheID) { cursor in
            guard let credential, self.tmdbRevision == revision else { throw CancellationError() }
            let result = try await self.tmdbCatalog(catalog, page: cursor)
            let key = try MetadataCacheKey.catalog(catalog, page: cursor, credential: credential)
            return ContentPage(
                items: result.items, nextCursor: result.hasMore ? cursor + 1 : nil,
                cacheID: MetadataCacheKey.id(key))
        }
    }

    func relatedSource(_ details: TMDBEnrichment) -> ContentSource {
        let credential = tmdbCredential, revision = tmdbRevision
        let initialCacheID = credential.flatMap {
            try? MetadataCacheKey.recommendations(
                id: details.id, type: details.mediaType, page: 1, credential: $0)
        }.map(MetadataCacheKey.id)
        return ContentSource(initialCacheID: initialCacheID) { cursor in
            guard let credential, self.tmdbRevision == revision else { throw CancellationError() }
            let result = try await self.recommendations(for: details, page: cursor)
            let key = try MetadataCacheKey.recommendations(
                id: details.id, type: details.mediaType, page: cursor, credential: credential)
            return ContentPage(items: result.items, cacheID: MetadataCacheKey.id(key))
        }
    }

    func detailsCacheID(_ item: MediaItem) -> String? {
        tmdbCredential.map { MetadataCacheKey.id(MetadataCacheKey.details(item, credential: $0)) }
    }

    func episodesCacheID(_ item: MediaItem, details: TMDBEnrichment?, season: Int?) -> String? {
        guard let credential = tmdbCredential, let details, let season else { return nil }
        return MetadataCacheKey.id(
            MetadataCacheKey.episodes(item, id: details.id, season: season, credential: credential))
    }
}
