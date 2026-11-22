import Foundation

struct MetadataChanges: Equatable {
    let ids: Set<String>
    let revision = UUID()

    init(ids: Set<String> = []) { self.ids = ids }
}

/// Revision tokens invalidate screen tasks without embedding add-on URLs or credentials in task IDs.
struct ContentContext: Hashable {
    let addons: UUID
    let tmdb: UUID
}

struct ContentRequestID<Input: Equatable>: Equatable {
    let input: Input
    let context: ContentContext
}

/// Lets a screen reset its scroll view by request, using the request as the view's identity.
extension ContentRequestID: Hashable where Input: Hashable {}
