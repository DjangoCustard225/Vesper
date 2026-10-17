import SwiftUI
import VesperCore

@MainActor
@Observable
final class AppStore {
    let client: AddonClient
    @ObservationIgnored private let addonCache = ResponseCache(
        directory: AppStore.cacheDirectory.appendingPathComponent("Addons"))
    @ObservationIgnored private let tmdbCache = ResponseCache(
        directory: AppStore.cacheDirectory.appendingPathComponent("TMDB"))
    private(set) var addonRevision = UUID()

    private(set) var addons: [InstalledAddon] {
        didSet {
            guard addons != oldValue else { return }
            addonRevision = UUID()
            home.cancel()
        }
    }
    private let home = HomeFeedController()

    var feeds: [CatalogFeed] { home.feeds }

    var tmdbFeeds: [TMDBFeed] { tmdbCredential == nil ? [] : home.tmdbFeeds }
    private(set) var heroCatalogID: String
    private(set) var availablePlayers: [VideoPlayer]

    var preferredPlayer: VideoPlayer {
        didSet { AppPreferenceStorage.save(preferredPlayer) }
    }
    #if !VESPER_GO
    var playerGestures: PlayerGesturePreferences {
        didSet { AppPreferenceStorage.save(playerGestures) }
    }
    #endif

    var isLoading: Bool { home.isLoading }
    private(set) var isClearingCache = false
    private(set) var library = LibraryState()
    private let history = WatchProgressController(repository: WatchProgressStorage.repository)
    let trakt = TraktStore()

    var watchProgress: WatchProgress { history.state }
    #if !VESPER_GO
    var showContinueWatching: Bool {
        didSet { AppPreferenceStorage.saveContinueWatching(showContinueWatching) }
    }
    #endif
    private(set) var cacheChanges = MetadataChanges()
    private(set) var cacheVersions: [String: UUID] = [:]
    private var localStorageError: String?

    var storageError: String? {
        get { localStorageError ?? history.error }
        set {
            localStorageError = newValue
            history.error = nil
        }
    }
    var incomingAddon: String?
    var showInstall = false
    private(set) var tmdbCredential: String?
    private(set) var tmdbRevision = UUID()
    @ObservationIgnored private var tmdbClient: TMDBClient
    @ObservationIgnored private var cacheUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCacheUpdates: Set<String> = []
    private var libraryWritable = true
    private var addonsWritable = true

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "VesperMetadata")
    }

    // MARK: - Initialization

    init() {
        #if !VESPER_GO
        showContinueWatching = AppPreferenceStorage.showContinueWatching()
        playerGestures = AppPreferenceStorage.gestures()
        AppPreferenceStorage.removeRetiredPreferences()
        #endif
        client = AddonClient(cache: addonCache)
        tmdbClient = TMDBClient(cache: tmdbCache)
        let saved: [InstalledAddon]
        do { saved = try SecureStorage.load(.addons) ?? [] } catch {
            saved = []
            addonsWritable = false
            localStorageError = error.localizedDescription
        }
        addons = saved.filter { !AddonPolicy.isCinemeta($0) }
        let players = AppIdentity.detectedPlayers()
        availablePlayers = players
        let player = AppPreferenceStorage.preferredPlayer().availablePreference(in: players)
        preferredPlayer = player
        AppPreferenceStorage.save(player)
        do { tmdbCredential = try SecureStorage.load(.tmdbCredential) } catch {
            tmdbCredential = nil
            localStorageError = error.localizedDescription
        }
        do { heroCatalogID = try SecureStorage.load(.heroCatalog) ?? HeroCatalogSelection.automaticID } catch
        {
            heroCatalogID = HeroCatalogSelection.automaticID
            localStorageError = error.localizedDescription
        }
        if saved.count != addons.count {
            do { try SecureStorage.save(addons, for: .addons) } catch {
                localStorageError =
                    "The removed metadata provider couldn’t be cleared from Keychain. It is disabled for this session."
            }
        }
        do {
            let loaded = try LibraryStorage.load()
            library = loaded.state
            if loaded.recovered {
                localStorageError =
                    "Your library was recovered from its last saved copy. The damaged file has been preserved."
            }
        } catch {
            libraryWritable = false
            localStorageError = "Your saved library couldn’t be read. Its file has been preserved."
        }

    }
    // MARK: - Preferences and hero selection

    var enabledAddons: [InstalledAddon] { addons.filter(\.isEnabled) }

    func refreshPlayers() {
        availablePlayers = AppIdentity.detectedPlayers()
        let available = preferredPlayer.availablePreference(in: availablePlayers)
        if available != preferredPlayer { preferredPlayer = available }
    }

    var heroCatalogs: [HeroCatalog] {
        var catalogs =
            tmdbCredential == nil
            ? []
            : TMDBCatalog.allCases.map { catalog in
                HeroCatalog(
                    id: "tmdb:" + catalog.id, title: "TMDB · " + catalog.title,
                    items: tmdbFeeds.first { $0.catalog == catalog }?.items ?? [])
            }
        for addon in enabledAddons {
            for catalog in addon.manifest.catalogs where catalog.canRequest(with: catalog.defaultExtras) {
                let feedID = addon.id + ":" + catalog.type + ":" + catalog.id
                catalogs.append(
                    HeroCatalog(
                        id: "addon:" + feedID,
                        title: addon.manifest.name + " · " + catalog.title,
                        items: feeds.first { $0.id == feedID }?.items ?? []))
            }
        }
        return catalogs
    }

    var heroItems: [MediaItem] {
        HeroCatalogSelection.items(preferredID: heroCatalogID, catalogs: heroCatalogs)
    }

    func setHeroCatalog(_ id: String) {
        do {
            try SecureStorage.save(id, for: .heroCatalog)
            heroCatalogID = id
        } catch {
            localStorageError = error.localizedDescription
        }
    }

    var contentContext: ContentContext { ContentContext(addons: addonRevision, tmdb: tmdbRevision) }

    // MARK: - Add-on management

    func installReviewed(_ addon: InstalledAddon) throws {
        guard !AddonPolicy.isCinemeta(addon) else { throw TMDBProviderError.removedProvider }
        try requireReadableAddons()
        var updated = addons
        if let index = updated.firstIndex(where: { $0.id == addon.id }) {
            updated[index] = addon
        } else {
            updated.append(addon)
        }
        try SecureStorage.save(updated, for: .addons)
        addons = updated
    }

    func setEnabled(_ addon: InstalledAddon, _ enabled: Bool) {
        do { try requireReadableAddons() } catch {
            localStorageError = error.localizedDescription
            return
        }
        var updated = addons
        guard let index = updated.firstIndex(where: { $0.id == addon.id }) else { return }
        updated[index].isEnabled = enabled
        saveAddons(updated)
    }

    func remove(_ addon: InstalledAddon) {
        do { try requireReadableAddons() } catch {
            localStorageError = error.localizedDescription
            return
        }
        saveAddons(addons.filter { $0.id != addon.id })
    }

    private func requireReadableAddons() throws {
        guard !addonsWritable else { return }
        let saved = try SecureStorage.load(.addons) ?? []
        addons = saved.filter { !AddonPolicy.isCinemeta($0) }
        addonsWritable = true
    }

    private func saveAddons(_ updated: [InstalledAddon]) {
        do {
            try SecureStorage.save(updated, for: .addons)
            addons = updated
            Task { await addonCache.clear() }
        } catch { localStorageError = error.localizedDescription }
    }
    // MARK: - TMDB credentials and cache lifecycle

    func saveTMDBCredential(_ input: String) async throws {
        let credential = try TMDBClient.normalizedCredential(input)
        // Verify before replacing a working saved key.
        try await TMDBClient().validate(credential: credential)
        try Task.checkCancellation()
        await tmdbClient.invalidate()
        try Task.checkCancellation()
        try SecureStorage.save(credential, for: .tmdbCredential)
        tmdbClient = TMDBClient(cache: tmdbCache)
        tmdbCredential = credential
        tmdbRevision = UUID()
        home.cancel()
    }

    func removeTMDBCredential() throws {
        try SecureStorage.delete(.tmdbCredential)
        tmdbCredential = nil
        let previous = tmdbClient
        tmdbClient = TMDBClient(cache: tmdbCache)
        Task { await previous.invalidate() }
        tmdbRevision = UUID()
        home.cancel()
    }

    func metadataRevision(for ids: [String?]) -> String {
        ids.compactMap { $0 }.sorted().compactMap { cacheVersions[$0]?.uuidString }.joined()
    }

    func clearCache() async throws {
        guard !isClearingCache else { return }
        isClearingCache = true
        defer { isClearingCache = false }
        cacheUpdateTask?.cancel()
        cacheUpdateTask = nil
        pendingCacheUpdates = []
        home.cancel()
        // Old requests keep their own client; they cannot refill the new client's memory.
        let previous = tmdbClient
        tmdbClient = TMDBClient(cache: tmdbCache)
        var failed = false
        do { try await client.clearCache() } catch { failed = true }
        do { try await previous.clearCache() } catch { failed = true }
        await ArtworkPipeline.shared.clearCache()
        cacheVersions = [:]
        tmdbRevision = UUID()
        home.cancel()
        if failed { throw CacheClearingError.incomplete }
    }

    func metadataDidRefresh(_ update: MetadataUpdate) {
        guard !isClearingCache else { return }
        pendingCacheUpdates.insert(update.cacheID)
        cacheUpdateTask?.cancel()
        cacheUpdateTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
            } catch {
                return
            }
            let ids = pendingCacheUpdates
            pendingCacheUpdates = []
            for id in ids { cacheVersions[id] = UUID() }
            cacheChanges = MetadataChanges(ids: ids)
            cacheUpdateTask = nil
            home.refresh(cacheIDs: ids)
        }
    }
    // MARK: - Metadata access

    func identifiedItems(_ items: [MediaItem], resolveUnknown: Bool = true) async -> [MediaItem] {
        guard let credential = tmdbCredential else { return MediaIdentity.unique(items) }
        let revision = tmdbRevision, api = tmdbClient
        var result = items
        await ConcurrentWork.run(
            items, limit: 3,
            operation: { item in
                (try? await api.identified(item, credential: credential, resolveUnknown: resolveUnknown))
                    ?? item
            }
        ) { index, item in
            guard revision == self.tmdbRevision else { return }
            result[index] = item
        }
        guard !Task.isCancelled, revision == tmdbRevision else { return items }
        return MediaIdentity.unique(result)
    }
    // Every TMDB operation uses one credential snapshot and discards results
    // if Settings replaced that credential while a request was in flight.
    private func withTMDB<Result>(_ operation: (TMDBClient, String) async throws -> Result) async throws
        -> Result
    {
        guard !isClearingCache else { throw CancellationError() }
        guard let credential = tmdbCredential else { throw TMDBError.invalidCredential }
        let revision = tmdbRevision
        let result = try await operation(tmdbClient, credential)
        try Task.checkCancellation()
        guard !isClearingCache, revision == tmdbRevision else { throw CancellationError() }
        return result
    }

    func enrichedMetadata(for item: MediaItem) async throws -> TMDBEnrichment? {
        guard tmdbCredential != nil else { return nil }
        return try await withTMDB { try await $0.enrichment(for: item, credential: $1) }
    }

    func tmdbCatalog(_ catalog: TMDBCatalog, page: Int = 1) async throws -> TMDBPage {
        try await withTMDB { try await $0.catalog(catalog, page: page, credential: $1) }
    }

    func tmdbSearch(_ term: String, page: Int = 1) async throws -> TMDBPage {
        try await withTMDB { try await $0.search(term, page: page, credential: $1) }
    }

    func filmography(personID: Int) async throws -> PersonFilmography {
        try await withTMDB { try await $0.filmography(personID: personID, credential: $1) }
    }

    func episodes(for media: MediaItem, details: TMDBEnrichment, season: Int) async throws -> [Episode] {
        try await withTMDB {
            try await $0.episodes(for: media, tmdbID: details.id, season: season, credential: $1)
        }
    }

    func recommendations(for details: TMDBEnrichment, page: Int = 1) async throws -> TMDBPage {
        try await withTMDB { api, credential in
            try await api.recommendations(
                tmdbID: details.id, mediaType: details.mediaType, page: page, credential: credential)
        }
    }
    // MARK: - Home and source discovery

    func refresh() async {
        await home.load(addons: enabledAddons, includeTMDB: tmdbCredential != nil) { catalog in
            switch catalog {
            case .addon(let feed): addonSource(feed)
            case .tmdb(let catalog): tmdbSource(catalog)
            }
        }
    }

    func metadata(for item: MediaItem) async -> (MediaItem, String?) {
        // TMDB owns movie/series metadata. Custom and live add-on IDs retain their provider details.
        if item.id.hasPrefix("tmdb:") || item.id.range(of: "^tt[0-9]+$", options: .regularExpression) != nil {
            return (item, nil)
        }
        var failed = false
        for addon in enabledAddons where addon.manifest.supports("meta", type: item.type, id: item.id) {
            do {
                if let full = try await client.meta(addon, item: item) { return (full, nil) }
            } catch is CancellationError { return (item, nil) } catch { failed = true }
        }
        return (item, failed ? "Some details couldn’t be loaded. Try again." : nil)
    }

    func streamOptions(
        type: String, videoID: String, embedded: [StreamSource]?,
        onUpdate: (@MainActor (StreamResults) -> Void)? = nil
    ) async -> StreamResults {
        await StreamDiscovery(client: client).load(
            addons: enabledAddons, type: type, videoID: videoID,
            embedded: embedded, onUpdate: onUpdate)
    }

    func freshSource(_ option: StreamOption, type: String, videoID: String) async throws -> StreamSource {
        try await StreamPolicy.freshSource(option.source, fetchedAt: option.fetchedAt) {
            if let provider = option.provider {
                guard enabledAddons.contains(where: { $0.id == provider.id }) else {
                    throw PlaybackError.sourceChanged
                }
                return try await client.streams(provider, type: type, videoID: videoID)
            }
            return await streamOptions(type: type, videoID: videoID, embedded: nil).options.map(\.source)
        }
    }
    // MARK: - Library and watched state

    func contains(_ item: MediaItem) -> Bool { library.items.contains { $0.isSameTitle(as: item) } }

    func setWatched(_ watched: Bool, for item: MediaItem) {
        let revision = trakt.connectionRevision
        let saved = history.setWatched(watched, for: item)
        let change = TraktHistoryChange(media: item, action: watched ? .watched : .unwatched)
        Task {
            guard await saved.value, revision == trakt.connectionRevision else { return }
            trakt.enqueue(change, history: history)
        }
    }

    func connectTrakt() { trakt.startSignIn(history: history) }

    func syncTrakt(force: Bool = false) async { await trakt.synchronize(history: history, force: force) }

    func resumeTrakt() async { await trakt.resume(history: history) }

    func disconnectTrakt() async { await trakt.disconnect(history: history) }
    #if !VESPER_GO
    func recordPlayback(media: MediaItem, video: VideoSelection, update: PlaybackProgressUpdate) {
        history.record(media: media, videoID: video.id, subtitle: video.title, update: update)
    }

    func scrobble(_ event: TraktScrobbleEvent, media: MediaItem, videoID: String) {
        trakt.receive(event, media: media, videoID: videoID, history: history)
    }
    #endif

    func flushWatchProgress() async { await history.flush() }

    func toggleLibrary(_ item: MediaItem) {
        var proposed = library
        if contains(item) {
            proposed.items.removeAll { $0.isSameTitle(as: item) }
        } else {
            proposed.items.insert(item, at: 0)
        }
        commitLibrary(proposed)
    }

    private func commitLibrary(_ proposed: LibraryState) {
        guard libraryWritable else {
            localStorageError =
                "Your library couldn’t be read. Restore a valid backup before making changes."

            return
        }
        do { try LibraryStorage.repository.commit(proposed, current: &library) } catch {
            localStorageError = error.localizedDescription
        }
    }

    func exportLibrary() throws -> Data {
        guard libraryWritable else { throw LibraryError.unreadable }
        return try LibraryRepository.encode(library)
    }

    func restoreLibrary(_ data: Data) throws {
        let restored = try LibraryRepository.decode(data)
        let merged = LibraryRepository.merging(restored, into: library)
        try LibraryStorage.repository.commit(merged, current: &library)
        libraryWritable = true
    }
}

private enum TMDBProviderError: LocalizedError {
    case removedProvider

    var errorDescription: String? {
        "TMDB provides movie and series metadata. Add streaming, subtitle, or other catalog add-ons instead."
    }
}

private enum CacheClearingError: LocalizedError {
    case incomplete

    var errorDescription: String? { "Some cached files couldn’t be cleared. Try again." }
}
