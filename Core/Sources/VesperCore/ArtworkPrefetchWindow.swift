import Foundation

public enum ArtworkPrefetchWindow {
    /// One viewport in the direction of travel, excluding already visible artwork.
    public static func urls(items: [MediaItem], visibleKeys: Set<String>, forward: Bool = true) -> [URL] {
        let visible = items.indices.filter { visibleKeys.contains(items[$0].key) }
        guard let first = visible.first, let last = visible.last else { return [] }
        let count = visible.count
        let indices = forward ? Array((last + 1)..<min(items.count, last + 1 + count))
            : Array((max(0, first - count)..<first).reversed())
        var seen = Set<URL>()
        return indices.compactMap { index in
            guard let raw = items[index].poster, let url = try? AddonURL.http(raw), seen.insert(url).inserted else { return nil }
            return url
        }
    }
}
