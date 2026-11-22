import Foundation

/// Finds values by title identity without comparing every pair. `first(matching:)` returns the
/// same value as `values.first { media($0).isSameTitle(as: item) }`: aliases carry the media type,
/// so sharing one means the same type and an overlapping identity.
public struct TitleIndex<Value> {
    private let values: [Value]
    private var positions: [String: Int] = [:]

    public init(_ values: [Value], media: (Value) -> MediaItem) {
        self.values = values
        for (index, value) in values.enumerated() {
            for alias in MediaIdentity.aliases(media(value)) where positions[alias] == nil {
                positions[alias] = index
            }
        }
    }

    public func first(matching item: MediaItem) -> Value? {
        MediaIdentity.aliases(item).compactMap { positions[$0] }.min().map { values[$0] }
    }

    public func contains(_ item: MediaItem) -> Bool {
        MediaIdentity.aliases(item).contains { positions[$0] != nil }
    }
}

extension TitleIndex where Value == MediaItem {
    public init(_ items: [MediaItem]) { self.init(items, media: { $0 }) }
}
