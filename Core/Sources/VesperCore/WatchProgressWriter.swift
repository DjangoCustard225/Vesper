import Foundation

/// Serializes progress writes away from the main actor.
public actor WatchProgressWriter {
    private let repository: WatchProgressRepository

    public init(repository: WatchProgressRepository) { self.repository = repository }

    public func save(_ state: WatchProgress) throws { try repository.save(state) }
}
