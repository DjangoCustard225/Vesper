import Foundation

/// Serializes library writes away from the main actor. Encoding, validation and the backup copy
/// all happen here, so saving a title never blocks the interface.
public actor LibraryWriter {
    private let repository: LibraryRepository

    public init(repository: LibraryRepository) { self.repository = repository }

    /// Saves `state` and returns it as stored, with duplicates merged and episode lists dropped.
    public func save(_ state: LibraryState) throws -> LibraryState {
        var stored = state
        try repository.commit(state, current: &stored)
        return stored
    }
}
