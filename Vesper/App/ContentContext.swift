import Foundation

struct MetadataChanges: Equatable {
    let ids: Set<String>
    let revision = UUID()

    init(ids: Set<String> = []) { self.ids = ids }
}

/// Revision tokens invalidate screen tasks without embedding add-on URLs or credentials in task IDs.
struct ContentContext: Equatable {
    let addons: UUID
    let tmdb: UUID
}

struct ContentRequestID<Input: Equatable>: Equatable {
    let input: Input
    let context: ContentContext
}
