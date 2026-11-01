import Foundation

public struct CatalogCustomization: Codable, Equatable, Sendable {
    public var isHidden: Bool
    public var name: String?
    public var filters: [String: String]

    public init(isHidden: Bool = false, name: String? = nil, filters: [String: String] = [:]) {
        self.isHidden = isHidden
        self.name = name
        self.filters = filters
    }
}

/// A presentation group retains source IDs even while their provider is unavailable.
public struct CombinedCatalog: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var members: [String]

    public init(id: String = "group:" + UUID().uuidString, name: String, members: [String]) {
        self.id = id
        self.name = name
        var seen = Set<String>()
        self.members = members.filter { !$0.hasPrefix("group:") && seen.insert($0).inserted }
    }

    public static func alternating(_ sources: [[MediaItem]]) -> [MediaItem] {
        var result: [MediaItem] = []
        for index in 0..<(sources.map(\.count).max() ?? 0) {
            for source in sources where index < source.count { result.append(source[index]) }
        }
        return MediaIdentity.unique(result)
    }
}

public struct CatalogPreferences: Codable, Equatable, Sendable {
    public var groups: [CombinedCatalog]
    public var order: [String]
    public var customizations: [String: CatalogCustomization]

    public init(
        order: [String] = [], customizations: [String: CatalogCustomization] = [:],
        groups: [CombinedCatalog] = []
    ) {
        self.groups = groups
        self.order = order
        self.customizations = customizations
    }

    private enum CodingKeys: String, CodingKey { case order, customizations, groups }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
        customizations =
            try values.decodeIfPresent([String: CatalogCustomization].self, forKey: .customizations) ?? [:]
        groups = try values.decodeIfPresent([CombinedCatalog].self, forKey: .groups) ?? []
    }

    public func isGrouped(_ id: String) -> Bool { groups.contains { $0.members.contains(id) } }

    public func isVisible(_ catalog: HomeCatalog) -> Bool {
        !customization(for: catalog.id).isHidden && !isGrouped(catalog.id)
    }

    public func members(of group: CombinedCatalog, in catalogs: [HomeCatalog]) -> [HomeCatalog] {
        group.members.compactMap { id in
            catalogs.first { catalog in
                guard catalog.id == id else { return false }
                if case .combined = catalog { return false }
                return true
            }
        }
    }

    public func customization(for id: String) -> CatalogCustomization {
        customizations[id] ?? CatalogCustomization()
    }

    public func title(for catalog: HomeCatalog) -> String {
        let name = customization(for: catalog.id).name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? catalog.title
    }

    public func extras(for catalog: HomeCatalog) -> [String: String] {
        guard case .addon(let feed) = catalog else { return [:] }
        return feed.catalog.effectiveExtras(customization(for: catalog.id).filters)
    }

    public func ordered(_ catalogs: [HomeCatalog]) -> [HomeCatalog] {
        var available: [String: HomeCatalog] = [:]
        for catalog in catalogs where available[catalog.id] == nil { available[catalog.id] = catalog }
        var seen = Set<String>()
        return (order + catalogs.map(\.id)).compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return available[id]
        }
    }

    public func requested(_ catalogs: [HomeCatalog], heroID: String) -> [HomeCatalog] {
        let selected = ordered(catalogs).filter { isVisible($0) || $0.id == heroID }
        let expanded = selected.flatMap { catalog -> [HomeCatalog] in
            if case .combined(let group) = catalog { return members(of: group, in: catalogs) }
            return [catalog]
        }
        var seen = Set<String>()
        return expanded.filter { catalog in
            guard seen.insert(catalog.id).inserted else { return false }
            if case .addon(let feed) = catalog {
                return feed.addon.isEnabled && feed.catalog.canRequest(with: extras(for: catalog))
            }
            return true
        }
    }

    /// Presentation-only edits have the same request signature and do not restart Home loading.
    public func requests(_ catalogs: [HomeCatalog], heroID: String) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: requested(catalogs, heroID: heroID).map { ($0.id, extras(for: $0)) })
    }
}

public struct CatalogFilter: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let options: [String]
    public let isRequired: Bool
}

extension AddonCatalog {
    public var filters: [CatalogFilter] {
        var seen = Set<String>()
        var result: [CatalogFilter] = []
        for field in extra ?? [] where field.name != "search" && field.name != "skip" {
            guard seen.insert(field.name).inserted else { continue }
            let choices = field.name == "genre" ? genres : field.options ?? []
            if let filter = filter(name: field.name, options: choices) { result.append(filter) }
        }
        if !seen.contains("genre"), let genre = filter(name: "genre", options: genres) {
            result.append(genre)
        }
        return result
    }

    public func effectiveExtras(_ selections: [String: String]) -> [String: String] {
        var result = defaultExtras
        for filter in filters {
            if let value = selections[filter.id], filter.options.contains(value) { result[filter.id] = value }
        }
        return result
    }

    private func filter(name: String, options: [String]) -> CatalogFilter? {
        var seen = Set<String>()
        let choices = options.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !choices.isEmpty else { return nil }
        return CatalogFilter(
            id: name,
            title: name == "genre" ? genreLabel : name.replacingOccurrences(of: "_", with: " ").capitalized,
            options: choices, isRequired: requiredExtras.contains(name))
    }
}

extension HomeCatalog: Identifiable {
    public var id: String {
        switch self {
        case .addon(let feed): "addon:" + feed.id
        case .tmdb(let catalog): "tmdb:" + catalog.id
        case .combined(let group): group.id
        }
    }

    public var title: String {
        switch self {
        case .addon(let feed): feed.catalog.title
        case .tmdb(let catalog): catalog.title
        case .combined(let group): group.name
        }
    }

    public var providerName: String {
        switch self {
        case .addon(let feed): feed.addon.manifest.name
        case .tmdb: "Vesper"
        case .combined: "Combined catalog"
        }
    }

    public static func catalogs(addons: [InstalledAddon], includeTMDB: Bool) -> [HomeCatalog] {
        let builtIn = includeTMDB ? TMDBCatalog.allCases.map(HomeCatalog.tmdb) : []
        return builtIn
            + addons.flatMap { addon in
                addon.manifest.catalogs.filter { $0.canRequest(with: $0.defaultExtras) }
                    .map { .addon(CatalogFeed(addon: addon, catalog: $0)) }
            }
    }
}
