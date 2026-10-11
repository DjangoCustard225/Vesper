import Foundation

/// Notifications carry opaque identifiers, never credential-bearing URLs or cache keys.
public struct MetadataUpdate: Sendable {
    public let cacheID: String
    public init(key: String) { cacheID = ResponseCache.fingerprint(key) }
}

public enum MetadataCacheKey {
    public static func addonCatalog(_ addon: InstalledAddon, _ catalog: AddonCatalog, extras: [String: String]) throws -> String {
        "catalog:" + (try AddonURL.resource(manifest: addon.manifestURL, resource: "catalog", type: catalog.type, id: catalog.id, extras: extras)).absoluteString
    }
    public static func listing(credential: String, path: [String], page: Int, query: [URLQueryItem] = []) throws -> String {
        let credential = try TMDBClient.normalizedCredential(credential)
        let parameters = query + [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "language", value: "en-US")]
        let request = try TMDBClient.request(path: path, query: parameters, credential: credential)
        return credential + ":listing:" + request.url!.absoluteString
    }
    public static func catalog(_ catalog: TMDBCatalog, page: Int, credential: String) throws -> String {
        try listing(credential: credential, path: catalog.path, page: page)
    }
    public static func search(_ term: String, page: Int, credential: String) throws -> String {
        try listing(credential: credential, path: ["search", "multi"], page: page,
            query: [URLQueryItem(name: "query", value: term), URLQueryItem(name: "include_adult", value: "false")])
    }
    public static func recommendations(id: Int, type: String, page: Int = 1, credential: String) throws -> String {
        try listing(credential: credential, path: [type, String(id), "recommendations"], page: page)
    }
    public static func details(_ item: MediaItem, credential: String) -> String { credential + ":details:" + item.key }
    public static func episodes(_ item: MediaItem, id: Int, season: Int, credential: String) -> String {
        credential + ":episodes:\(id):\(season):" + item.playbackID
    }
    public static func id(_ key: String) -> String { ResponseCache.fingerprint(key) }
}
