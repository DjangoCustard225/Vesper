import Foundation
import Observation
import UsenetEngine
import VesperCore

@MainActor @Observable final class NZBFinderService {
    static let shared = NZBFinderService()
    private(set) var apiKey: String?
    private(set) var enabled = false
    private(set) var storageError: String?
    private(set) var revision = UUID()
    @ObservationIgnored private let client = NZBFinderClient()
    private static let packsKey = "NZBFinder.seasonPacks"
    private(set) var includeSeasonPacks =
        UserDefaults.standard.object(forKey: "NZBFinder.seasonPacks") as? Bool ?? true
    private static let enabledKey = "NZBFinder.enabled"
    private init() {
        do { apiKey = try SecureStorage.load(.nzbfinderAPIKey) } catch {
            storageError = error.localizedDescription
        }
        enabled = apiKey != nil && UserDefaults.standard.bool(forKey: Self.enabledKey)
    }
    func save(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client.verify(apiKey: key)
        try Task.checkCancellation()
        await client.invalidate()
        try Task.checkCancellation()
        try SecureStorage.save(key, for: .nzbfinderAPIKey)
        apiKey = key; storageError = nil; setEnabled(true)
    }
    func setEnabled(_ value: Bool) {
        enabled = value && apiKey != nil
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey); revision = UUID()
    }
    func setIncludeSeasonPacks(_ value: Bool) {
        includeSeasonPacks = value; UserDefaults.standard.set(value, forKey: Self.packsKey); revision = UUID()
    }
    func remove() async throws {
        try SecureStorage.delete(.nzbfinderAPIKey)
        apiKey = nil; storageError = nil; setEnabled(false)
        await client.invalidate()
    }
    func search(_ context: NZBSearchContext, cursor: NZBSearchCursor?, refresh: Bool = false) async throws
        -> NZBSearchPage
    {
        guard enabled, let apiKey else { throw NZBFinderError.missingKey }
        let revision = revision
        let page = try await client.search(context, apiKey: apiKey, cursor: cursor, refresh: refresh)
        guard self.revision == revision, enabled else { throw CancellationError() }; return page
    }
    func nzb(_ release: NZBRelease) async throws -> NZBDownload {
        // Do not spend an indexer download before playback has a usable provider.
        guard let provider = UsenetService.shared.provider else { throw UsenetError.providerRequired }
        _ = try provider.validated()
        guard enabled, let apiKey else { throw NZBFinderError.missingKey }
        let revision = revision
        let bytes = try await client.download(release, apiKey: apiKey)
        guard self.revision == revision, enabled else { throw CancellationError() }; return bytes
    }
}
