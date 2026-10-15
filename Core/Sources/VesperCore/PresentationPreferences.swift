import Foundation

public struct HeroCatalog: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let items: [MediaItem]

    public init(id: String, title: String, items: [MediaItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public enum HeroCatalogSelection {
    public static let automaticID = "automatic"

    public static func items(preferredID: String, catalogs: [HeroCatalog]) -> [MediaItem] {
        guard
            let catalog = catalogs.first(where: { $0.id == preferredID && !$0.items.isEmpty })
                ?? catalogs.first(where: { !$0.items.isEmpty })
        else { return [] }
        return Array(MediaIdentity.unique(catalog.items).prefix(20))
    }
}

public struct CatalogPagination {
    public let items: [MediaItem]
    public let hasMore: Bool

    public init(
        existing: [MediaItem], incoming: [MediaItem], providerHasMore: Bool, allowEmptyPages: Bool = false
    ) {
        let previous = MediaIdentity.unique(existing)
        let previousCount = previous.count
        items = MediaIdentity.unique(previous + incoming)
        hasMore = providerHasMore && (items.count > previousCount || (allowEmptyPages && incoming.isEmpty))
    }
}
