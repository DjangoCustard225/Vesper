import Foundation

public enum ArtworkPrefetchWindow {
    public struct Row: Sendable {
        public let id: String
        public let items: [MediaItem]
        public init(id: String, items: [MediaItem]) {
            self.id = id
            self.items = items
        }
    }

    /// Only the first screen of the next populated Home row, never an entire catalog.
    public static func urls(
        rows: [Row], visibleRows: Set<String>, forward: Bool = true, posterCount: Int
    ) -> [URL] {
        let populated = rows.filter { !$0.items.isEmpty }
        guard posterCount > 0, !populated.isEmpty else { return [] }
        let visible = populated.indices.filter { visibleRows.contains(populated[$0].id) }
        let index: Int
        if let first = visible.first, let last = visible.last {
            index = forward ? last + 1 : first - 1
        } else {
            index = forward ? 0 : populated.count - 1
        }
        guard populated.indices.contains(index) else { return [] }
        return posterURLs(populated[index].items.prefix(posterCount))
    }

    /// One viewport in the direction of travel, excluding already visible artwork.
    public static func urls(items: [MediaItem], visibleKeys: Set<String>, forward: Bool = true) -> [URL] {
        let visible = items.indices.filter { visibleKeys.contains(items[$0].key) }
        guard let first = visible.first, let last = visible.last else { return [] }
        let count = visible.count
        let indices =
            forward
            ? Array((last + 1)..<min(items.count, last + 1 + count))
            : Array((max(0, first - count)..<first).reversed())
        return posterURLs(indices.lazy.map { items[$0] })
    }

    private static func posterURLs(_ items: some Sequence<MediaItem>) -> [URL] {
        var seen = Set<URL>()
        return items.compactMap {
            guard let raw = $0.poster, let url = try? AddonURL.http(raw), seen.insert(url).inserted else {
                return nil
            }
            return url
        }
    }
}
