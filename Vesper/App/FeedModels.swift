import Foundation
import VesperCore

struct MetadataChanges: Equatable {
    let ids: Set<String>
    let revision = UUID()
    init(ids: Set<String> = []) { self.ids = ids }
}

struct CatalogFeed: Identifiable {
    let addon: InstalledAddon
    let catalog: AddonCatalog
    var items: [MediaItem] = []
    var error: String?
    var id: String { addon.id + ":" + catalog.type + ":" + catalog.id }
    var subtitle: String { addon.manifest.name + " · " + (catalog.type == "series" ? "Series" : catalog.type.capitalized) }
}

struct TMDBFeed: Identifiable {
    let catalog: TMDBCatalog
    var items: [MediaItem] = []
    var error: String?
    var id: String { catalog.id }
}
