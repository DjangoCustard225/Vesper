import Foundation

public struct AddonManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String?
    public let logo: String?
    public let resources: [AddonResource]
    public let types: [String]
    public let idPrefixes: [String]?
    public let catalogs: [AddonCatalog]
    public let behaviorHints: ManifestHints?

    public func supports(_ resource: String, type: String, id: String) -> Bool {
        resources.contains { entry in
            guard entry.name == resource else { return false }
            let supportedTypes = entry.isDetailed ? (entry.types ?? types) : types
            let prefixes = entry.isDetailed ? entry.idPrefixes : idPrefixes
            return supportedTypes.contains(type) && (prefixes == nil || prefixes!.contains { id.hasPrefix($0) })
        }
    }
}

public struct ManifestHints: Codable, Equatable, Sendable {
    public let configurable: Bool?
    public let configurationRequired: Bool?
}

public struct AddonResource: Codable, Equatable, Sendable {
    public let name: String
    public let types: [String]?
    public let idPrefixes: [String]?
    public let isDetailed: Bool
    private enum CodingKeys: String, CodingKey { case name, types, idPrefixes }

    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.name = name; types = nil; idPrefixes = nil; isDetailed = false
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            types = try c.decodeIfPresent([String].self, forKey: .types)
            idPrefixes = try c.decodeIfPresent([String].self, forKey: .idPrefixes)
            isDetailed = true
        }
    }
    public func encode(to encoder: Encoder) throws {
        if !isDetailed {
            var c = encoder.singleValueContainer(); try c.encode(name)
        } else {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(types, forKey: .types)
            try c.encodeIfPresent(idPrefixes, forKey: .idPrefixes)
        }
    }
}

public struct AddonCatalog: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let name: String?
    public let extra: [CatalogExtra]?
    public let extraSupported: [String]?
    public let extraRequired: [String]?
    public let legacyGenres: [String]?
    private enum CodingKeys: String, CodingKey {
        case id, type, name, extra, extraSupported, extraRequired
        case legacyGenres = "genres"
    }
    public var title: String { name ?? id.capitalized }
    public func supports(_ key: String) -> Bool { extra?.contains { $0.name == key } == true || extraSupported?.contains(key) == true }
    public var requiredExtras: [String] {
        Array(Set((extra?.filter { $0.isRequired == true }.map(\.name) ?? []) + (extraRequired ?? [])))
    }
    public var genres: [String] { extra?.first { $0.name == "genre" }?.options ?? legacyGenres ?? [] }
    public var genreLabel: String { !genres.isEmpty && genres.allSatisfy { Int($0) != nil } ? "Year" : "Genre" }
    public var defaultExtras: [String: String] {
        var values: [String: String] = [:]
        for key in requiredExtras {
            if let first = extra?.first(where: { $0.name == key })?.options?.first { values[key] = first }
            else if key == "genre", let first = genres.first { values[key] = first }
            else if key == "skip" { values[key] = "0" }
        }
        return values
    }
    public func canRequest(with extras: [String: String]) -> Bool {
        requiredExtras.allSatisfy { extras[$0]?.isEmpty == false }
    }
}

public struct CatalogExtra: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let isRequired: Bool?
    public let options: [String]?
}

public struct InstalledAddon: Codable, Equatable, Identifiable, Sendable {
    public let manifestURL: URL
    public var manifest: AddonManifest
    public var isEnabled: Bool
    public var id: String { manifestURL.absoluteString }
    public init(manifestURL: URL, manifest: AddonManifest, isEnabled: Bool = true) {
        self.manifestURL = manifestURL; self.manifest = manifest; self.isEnabled = isEnabled
    }
}

public struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let type: String
    public let name: String
    public var poster: String?
    public var background: String?
    public var description: String?
    public var releaseInfo: String?
    public var imdbRating: String?
    public var imdbID: String?
    public var tmdbID: Int? = nil
    public var tmdbRating: Double?
    public var playbackID: String { MediaIdentity.validIMDb(imdbID) ?? id }
    public func isSameTitle(as other: MediaItem) -> Bool {
        type == other.type && !MediaIdentity.aliases(self).isDisjoint(with: MediaIdentity.aliases(other))
    }
    public var runtime: String?
    public var genres: [String]?
    public var cast: [String]?
    public var director: [String]?
    public var videos: [Episode]?
    public var behaviorHints: MediaHints?
    public var key: String { type + ":" + id }
    public var typeLabel: String {
        switch type { case "movie": "Movie"; case "series": "Series"; case "tv": "Live TV"; default: type.capitalized }
    }
}

public struct MediaHints: Codable, Hashable, Sendable {
    public let defaultVideoId: String?
    public let isLive: Bool?
    public let hasScheduledVideos: Bool?
}

public struct Episode: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let name: String?
    public let season: Int?
    public let episode: Int?
    public let overview: String?
    public let thumbnail: String?
    public let released: String?
    public let streams: [StreamSource]?
    public let runtimeMinutes: Int?
    public var displayTitle: String { title ?? name ?? "Episode \(episode ?? 0)" }
    public var label: String {
        guard let season, let episode else { return displayTitle }
        return "S\(season) · E\(episode)"
    }
}

public struct StreamSource: Codable, Hashable, Sendable {
    public let name: String?
    public let title: String?
    public let description: String?
    public let url: String?
    public let externalUrl: String?
    public let ytId: String?
    public let infoHash: String?
    public let fileIdx: Int?
    public let sources: [String]?
    public let behaviorHints: StreamHints?
    public var label: String { name ?? "Stream" }
    public var detail: String { description ?? title ?? (infoHash != nil ? "Torrent · streaming server required" : "") }
}

public struct StreamHints: Codable, Hashable, Sendable {
    public let proxyHeaders: ProxyHeaders?
    public let videoHash: String?
    public let videoSize: Int64?
    public let filename: String?
}
public struct ProxyHeaders: Codable, Hashable, Sendable {
    public let request: [String: String]?
    public let response: [String: String]?
}

public struct CatalogResponse: Decodable, Sendable { public let metas: [MediaItem] }
public struct MetaResponse: Decodable, Sendable { public let meta: MediaItem? }
public struct StreamResponse: Decodable, Sendable { public let streams: [StreamSource] }
