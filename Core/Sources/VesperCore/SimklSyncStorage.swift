import Foundation

/// Disk encoding and decoding stay on this actor rather than the UI executor.
public actor SimklSyncStorage {
    private let repository: SimklSyncRepository
    public init(repository: SimklSyncRepository) { self.repository = repository }
    public func load() throws -> SimklSyncState { try repository.load() }
    public func save(_ state: SimklSyncState) throws { try repository.save(state) }
}
