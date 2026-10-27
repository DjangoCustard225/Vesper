import Foundation

public enum MediaIdentity {
    public static func validIMDb(_ value: String?) -> String? {
        guard let value, value.hasPrefix("tt"), value.utf8.count > 2,
            value.utf8.dropFirst(2).allSatisfy({ (48...57).contains($0) })
        else { return nil }
        return value
    }

    public static func tmdbID(_ item: MediaItem) -> Int? {
        if let number = item.tmdbID, number > 0 { return number }
        let parts = item.id.split(separator: ":").map(String.init)
        let type = item.type == "series" ? "tv" : item.type
        guard ["movie", "series"].contains(item.type), parts.first == "tmdb", [2, 3].contains(parts.count),
            parts.count == 2 || parts[1] == type || (item.type == "series" && parts[1] == "series"),
            let number = Int(parts.last ?? ""), number > 0
        else { return nil }
        return number
    }

    public static func tvdbID(_ item: MediaItem) -> Int? {
        if let id = item.tvdbID, id > 0 { return id }
        let parts = item.id.split(separator: ":")
        guard item.type == "series", parts.count == 2, parts.first == "tvdb",
            let id = Int(parts[1]), id > 0
        else { return nil }
        return id
    }

    public static func aliases(_ item: MediaItem) -> Set<String> {
        var values: Set<String> = [item.type + ":raw:" + item.id]
        if let imdb = validIMDb(item.imdbID) ?? validIMDb(item.id) {
            values.insert(item.type + ":imdb:" + imdb)
        }
        if let tmdb = tmdbID(item) { values.insert(item.type + ":tmdb:" + String(tmdb)) }
        if let tvdb = tvdbID(item) { values.insert(item.type + ":tvdb:" + String(tvdb)) }
        return values
    }
    /// Exact IDs only. A matching name or year is never sufficient to merge titles.
    public static func unique(_ items: [MediaItem]) -> [MediaItem] {
        var parents = Array(items.indices), owners: [String: Int] = [:]
        func root(_ index: Int) -> Int {
            var node = index
            while parents[node] != node {
                // Path halving keeps repeated alias lookups cheap as catalogs grow.
                parents[node] = parents[parents[node]]
                node = parents[node]
            }
            return node
        }
        for (index, item) in items.enumerated() {
            for alias in aliases(item) {
                if let owner = owners[alias] {
                    let a = root(index), b = root(owner)
                    parents[max(a, b)] = min(a, b)
                } else {
                    owners[alias] = index
                }
            }
        }
        var results: [MediaItem] = [], indices: [Int: Int] = [:]
        for (index, item) in items.enumerated() {
            let key = root(index)
            if let position = indices[key] {
                var first = results[position]
                first.imdbID =
                    validIMDb(first.imdbID) ?? validIMDb(first.id) ?? validIMDb(item.imdbID)
                    ?? validIMDb(item.id)
                first.tmdbID = tmdbID(first) ?? tmdbID(item)
                first.tvdbID = tvdbID(first) ?? tvdbID(item)
                first.poster = first.poster ?? item.poster

                first.background = first.background ?? item.background
                first.description = first.description ?? item.description
                results[position] = first
            } else {
                indices[key] = results.count
                results.append(item)
            }
        }
        return results
    }

    public static func videoID(_ id: String, for media: MediaItem) -> String {
        if id == media.id || id == media.playbackID { return media.playbackID }
        guard media.type == "series" else { return id }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let season = Int(parts[parts.count - 2]), season >= 0,
            let episode = Int(parts[parts.count - 1]), episode > 0
        else { return id }
        let prefix = parts.dropLast(2).joined(separator: ":")
        let candidate = MediaItem(id: prefix, type: media.type, name: media.name)
        guard !aliases(candidate).isDisjoint(with: aliases(media)) else { return id }
        return "\(media.playbackID):\(season):\(episode)"
    }
}
