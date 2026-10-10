import SwiftUI
import VesperCore

@MainActor
@Observable
final class AppStore {
    let client = AddonClient()
    var addons: [InstalledAddon]
    var feeds: [CatalogFeed] = []
    var tmdbFeeds: [TMDBFeed] = []
    private(set) var heroCatalogID: String
    var preferredPlayer: VideoPlayer {
        didSet { UserDefaults.standard.set(preferredPlayer.rawValue, forKey: "preferredPlayer") }
    }
    var isLoading = false
    var library = LibraryState()
    var storageError: String?
    var incomingAddon: String?
    var showInstall = false
    let streamingServer: String
    private(set) var tmdbCredential: String?
    private(set) var tmdbRevision = UUID()
    @ObservationIgnored private var tmdbClient = TMDBClient()
    private var refreshID = UUID()
    private var libraryWritable = true

    init() {
        let saved = SecureStorage.load([InstalledAddon].self, key: "addons") ?? []
        addons = saved.filter { !AddonPolicy.isCinemeta($0) }
        let player = VideoPlayer.preferred(storedValue: UserDefaults.standard.string(forKey: "preferredPlayer"))
        preferredPlayer = player
        UserDefaults.standard.set(player.rawValue, forKey: "preferredPlayer")
        streamingServer = SecureStorage.load(String.self, key: "server") ?? ""
        tmdbCredential = SecureStorage.load(String.self, key: "tmdbCredential")
        heroCatalogID = SecureStorage.load(String.self, key: "heroCatalog") ?? HeroCatalogSelection.automaticID
        if saved.count != addons.count {
            do { try SecureStorage.save(addons, key: "addons") }
            catch { storageError = "The removed metadata provider couldn’t be cleared from Keychain. It is disabled for this session." }
        }
        do { library = try LibraryStorage.load() }
        catch {
            libraryWritable = false
            storageError = "Your saved library couldn’t be read. Its file has been preserved."
        }
    }
    var enabledAddons: [InstalledAddon] { addons.filter(\.isEnabled) }
    var heroCatalogs: [HeroCatalog] {
        var catalogs = tmdbCredential == nil ? [] : TMDBCatalog.allCases.map { catalog in
            HeroCatalog(id: "tmdb:" + catalog.id, title: "TMDB · " + catalog.title,
                        items: tmdbFeeds.first { $0.catalog == catalog }?.items ?? [])
        }
        for addon in enabledAddons {
            for catalog in addon.manifest.catalogs where catalog.canRequest(with: catalog.defaultExtras) {
                let feedID = addon.id + ":" + catalog.type + ":" + catalog.id
                catalogs.append(HeroCatalog(id: "addon:" + feedID,
                    title: addon.manifest.name + " · " + catalog.title,
                    items: feeds.first { $0.id == feedID }?.items ?? []))
            }
        }
        return catalogs
    }
    var heroItems: [MediaItem] { HeroCatalogSelection.items(preferredID: heroCatalogID, catalogs: heroCatalogs) }
    func setHeroCatalog(_ id: String) {
        do { try SecureStorage.save(id, key: "heroCatalog"); heroCatalogID = id }
        catch { storageError = error.localizedDescription }
    }
    var continueWatching: [WatchProgress] {
        library.history.filter { !$0.isFinished && $0.position > 5 }.sorted { $0.updated > $1.updated }
    }
    var addonSignature: String { addons.map { $0.id + String($0.isEnabled) + $0.manifest.version }.joined(separator: "|") }

    func installReviewed(_ addon: InstalledAddon) throws {
        guard !AddonPolicy.isCinemeta(addon) else { throw TMDBProviderError.removedProvider }
        var updated = addons
        if let index = updated.firstIndex(where: { $0.id == addon.id }) { updated[index] = addon }
        else { updated.append(addon) }
        try SecureStorage.save(updated, key: "addons")
        addons = updated
    }
    func setEnabled(_ addon: InstalledAddon, _ enabled: Bool) {
        var updated = addons
        guard let index = updated.firstIndex(where: { $0.id == addon.id }) else { return }
        updated[index].isEnabled = enabled
        saveAddons(updated)
    }
    func remove(_ addon: InstalledAddon) { saveAddons(addons.filter { $0.id != addon.id }) }
    private func saveAddons(_ updated: [InstalledAddon]) {
        do { try SecureStorage.save(updated, key: "addons"); addons = updated }
        catch { storageError = error.localizedDescription }
    }
    func saveTMDBCredential(_ input: String) async throws {
        let credential = try TMDBClient.normalizedCredential(input)
        // Verify before replacing a working saved key.
        try await tmdbClient.validate(credential: credential)
        try Task.checkCancellation()
        try SecureStorage.save(credential, key: "tmdbCredential")
        tmdbCredential = credential
        tmdbRevision = UUID()
    }
    func removeTMDBCredential() throws {
        try SecureStorage.delete(key: "tmdbCredential")
        tmdbCredential = nil
        tmdbFeeds = []
        tmdbClient = TMDBClient()
        tmdbRevision = UUID()
    }
    func enrichedMetadata(for item: MediaItem) async throws -> TMDBEnrichment? {
        guard let credential = tmdbCredential else { return nil }
        let revision = tmdbRevision
        let result = try await tmdbClient.enrichment(for: item, credential: credential)
        try Task.checkCancellation()
        guard revision == tmdbRevision else { throw CancellationError() }
        return result
    }
    func tmdbCatalog(_ catalog: TMDBCatalog, page: Int = 1) async throws -> TMDBPage {
        guard let credential = tmdbCredential else { throw TMDBError.invalidCredential }
        let revision = tmdbRevision
        let result = try await tmdbClient.catalog(catalog, page: page, credential: credential)
        try Task.checkCancellation()
        guard revision == tmdbRevision else { throw CancellationError() }
        return result
    }
    func tmdbSearch(_ term: String, page: Int = 1) async throws -> TMDBPage {
        guard let credential = tmdbCredential else { throw TMDBError.invalidCredential }
        let revision = tmdbRevision
        let result = try await tmdbClient.search(term, page: page, credential: credential)
        try Task.checkCancellation()
        guard revision == tmdbRevision else { throw CancellationError() }
        return result
    }
    func episodes(for media: MediaItem, details: TMDBEnrichment, season: Int) async throws -> [Episode] {
        guard let credential = tmdbCredential else { throw TMDBError.invalidCredential }
        let revision = tmdbRevision
        let result = try await tmdbClient.episodes(for: media, tmdbID: details.id, season: season, credential: credential)
        try Task.checkCancellation()
        guard revision == tmdbRevision else { throw CancellationError() }
        return result
    }
    func recommendations(for details: TMDBEnrichment, page: Int = 1) async throws -> TMDBPage {
        guard let credential = tmdbCredential else { throw TMDBError.invalidCredential }
        let revision = tmdbRevision
        let result = try await tmdbClient.recommendations(tmdbID: details.id, mediaType: details.mediaType,
                                                         page: page, credential: credential)
        try Task.checkCancellation()
        guard revision == tmdbRevision else { throw CancellationError() }
        return result
    }
    func refresh() async {
        let request = UUID(); refreshID = request
        isLoading = true
        let candidates = enabledAddons.flatMap { addon in
            addon.manifest.catalogs.filter { $0.canRequest(with: $0.defaultExtras) }.map { CatalogFeed(addon: addon, catalog: $0) }
        }
        // Preserve manifest order while fetching independently. One failed add-on doesn't hide the rest.
        var result = candidates
        let tmdbCandidates = tmdbCredential == nil ? [] : TMDBCatalog.allCases.map { TMDBFeed(catalog: $0) }
        var tmdbResult = tmdbCandidates
        for index in result.indices { result[index].items = feeds.first { $0.id == result[index].id }?.items ?? [] }
        for index in tmdbResult.indices { tmdbResult[index].items = tmdbFeeds.first { $0.id == tmdbResult[index].id }?.items ?? [] }
        feeds = result; tmdbFeeds = tmdbResult
        await withTaskGroup(of: (Int, [MediaItem], String?).self) { group in
            for (index, feed) in tmdbCandidates.enumerated() {
                group.addTask {
                    do { return (index, try await self.tmdbCatalog(feed.catalog).items, nil) }
                    catch is CancellationError { return (index, [], nil) }
                    catch { return (index, [], error.localizedDescription) }
                }
            }
            for (index, feed) in candidates.enumerated() {
                group.addTask { [client] in
                    do { return (index + tmdbCandidates.count, try await client.catalog(feed.addon, feed.catalog, extras: feed.catalog.defaultExtras), nil) }
                    catch is CancellationError { return (index + tmdbCandidates.count, [], nil) }
                    catch { return (index + tmdbCandidates.count, [], error.localizedDescription) }
                }
            }
            for await (index, items, error) in group {
                guard refreshID == request, !Task.isCancelled else { group.cancelAll(); return }
                if index < tmdbCandidates.count {
                    tmdbResult[index].items = Self.unique(items); tmdbResult[index].error = error
                    tmdbFeeds = tmdbResult
                } else {
                    result[index - tmdbCandidates.count].items = Self.unique(items); result[index - tmdbCandidates.count].error = error
                    feeds = result
                }
            }
        }
        guard refreshID == request else { return }
        feeds = result
        tmdbFeeds = tmdbResult
        isLoading = false
    }
    nonisolated static func unique(_ items: [MediaItem]) -> [MediaItem] {
        var keys = Set<String>()
        return items.filter { keys.insert($0.key).inserted }
    }
    func metadata(for item: MediaItem) async -> (MediaItem, String?) {
        // TMDB owns movie/series metadata. Custom and live add-on IDs retain their provider details.
        if item.id.hasPrefix("tmdb:") || item.id.range(of: "^tt[0-9]+$", options: .regularExpression) != nil { return (item, nil) }
        var failed = false
        for addon in enabledAddons where addon.manifest.supports("meta", type: item.type, id: item.id) {
            do {
                if let full = try await client.meta(addon, item: item) { return (full, nil) }
            } catch is CancellationError { return (item, nil) }
            catch { failed = true }
        }
        return (item, failed ? "Some details couldn’t be loaded. Try again." : nil)
    }
    func streamOptions(type: String, videoID: String, embedded: [StreamSource]?, onUpdate: ((StreamResults) -> Void)? = nil) async -> StreamResults {
        if let embedded { return StreamResults(options: embedded.map { StreamOption(addonName: "Included source", source: $0) }) }
        let providers = enabledAddons.filter { $0.manifest.supports("stream", type: type, id: videoID) }
        var results: [(Int, [StreamOption], String?)] = []
        await withTaskGroup(of: (Int, [StreamOption], String?).self) { group in
            for (index, addon) in providers.enumerated() {
                group.addTask { [client] in
                    do {
                        let sources = try await client.streams(addon, type: type, videoID: videoID)
                        return (index, sources.map { StreamOption(addonName: addon.manifest.name, source: $0) }, nil)
                    } catch is CancellationError { return (index, [], nil) }
                    catch { return (index, [], addon.manifest.name + ": " + error.localizedDescription) }
                }
            }
            for await result in group {
                guard !Task.isCancelled else { group.cancelAll(); return }
                results.append(result)
                let ordered = results.sorted { $0.0 < $1.0 }
                onUpdate?(StreamResults(options: ordered.flatMap(\.1), failures: ordered.compactMap(\.2)))
            }
        }
        let ordered = results.sorted { $0.0 < $1.0 }
        return StreamResults(options: ordered.flatMap(\.1), failures: ordered.compactMap(\.2))
    }
    func contains(_ item: MediaItem) -> Bool { library.items.contains { $0.isSameTitle(as: item) } }
    func toggleLibrary(_ item: MediaItem) {
        if contains(item) { library.items.removeAll { $0.isSameTitle(as: item) } }
        else { library.items.insert(libraryMetadata(item), at: 0) }
        persistLibrary()
    }
    func progress(for item: MediaItem, videoID: String) -> WatchProgress? {
        library.history.first { $0.media.isSameTitle(as: item) && $0.videoID == videoID }
    }
    func removeProgress(_ progress: WatchProgress) {
        library.history.removeAll { $0.id == progress.id }; persistLibrary()
    }
    func clearHistory() { library.history = []; persistLibrary() }
    private func libraryMetadata(_ item: MediaItem) -> MediaItem {
        // Fetch episode details on demand rather than persisting complete series and expiring stream URLs for every watch entry.
        var compact = item
        compact.videos = nil
        return compact
    }
    private func persistLibrary() {
        guard libraryWritable else { return }
        do { try LibraryStorage.save(library) }
        catch { storageError = error.localizedDescription }
    }
}

private enum TMDBProviderError: LocalizedError {
    case removedProvider
    var errorDescription: String? { "TMDB provides movie and series metadata. Add streaming, subtitle, or other catalog add-ons instead." }
}
