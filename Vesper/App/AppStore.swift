import SwiftUI
import VesperCore

@MainActor
@Observable
final class AppStore {
    let downloads = DownloadManager.shared
    let client: AddonClient
    @ObservationIgnored private let addonCache = ResponseCache(
        directory: AppStore.cacheDirectory.appendingPathComponent("Addons"))
    @ObservationIgnored private let tmdbCache = ResponseCache(
        directory: AppStore.cacheDirectory.appendingPathComponent("TMDB"))
    @ObservationIgnored private let tvdbCache = ResponseCache(
        directory: AppStore.cacheDirectory.appendingPathComponent("TVDB"))
    @ObservationIgnored private let detailPosters = DetailPosterValidator(
        cache: ResponseCache(directory: AppStore.cacheDirectory.appendingPathComponent("DetailPosters")))
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
    private(set) var catalogPreferences = CatalogPreferences()
    private(set) var homeCatalogRevision = UUID()
    @ObservationIgnored private var catalogsWritable = true
    private(set) var heroCatalogID: String
    private(set) var availablePlayers: [VideoPlayer]

    var showAllExternalPlayers: Bool {
        didSet {
            AppPreferenceStorage.saveShowAllExternalPlayers(showAllExternalPlayers)
            refreshPlayers()
        }
    }

    var preferredPlayer: VideoPlayer {
        didSet { AppPreferenceStorage.save(preferredPlayer) }
    }
    @ObservationIgnored private let ratingsClient = MDBListClient(
        cache: ResponseCache(
            directory: AppStore.cacheDirectory.appendingPathComponent("MDBList"), byteLimit: 4 * 1024 * 1024))
    @ObservationIgnored private let introClient = IntroDBClient(
        cache: ResponseCache(
            directory: AppStore.cacheDirectory.appendingPathComponent("IntroDB")))
    var showSkipIntro: Bool {
        didSet { AppPreferenceStorage.saveShowSkipIntro(showSkipIntro) }
    }
    var playerGestures: PlayerGesturePreferences {
        didSet { AppPreferenceStorage.save(playerGestures) }
    }

    var isLoading: Bool { home.isLoading }
    private var catalogLayoutRevision = UUID()
    @ObservationIgnored private var cachedCatalogPresentation:
        (
            key: CatalogPresentationKey, value: HomeCatalogPresentation
        )?

    private struct CatalogPresentationKey: Equatable {
        let layout: UUID
        let context: ContentContext
        let feeds: UUID
        let hero: String
    }

    var catalogPresentation: HomeCatalogPresentation {
        let key = CatalogPresentationKey(
            layout: catalogLayoutRevision, context: contentContext,
            feeds: home.presentationRevision, hero: heroCatalogID)
        if let cachedCatalogPresentation, cachedCatalogPresentation.key == key {
            return cachedCatalogPresentation.value
        }
        let value = HomeCatalogPresentation(
            addons: addons, tmdbConfigured: tmdbCredential != nil, preferences: catalogPreferences,
            feeds: home.feeds, tmdbFeeds: home.tmdbFeeds, settledCatalogIDs: home.settledCatalogIDs,
            isLoading: home.isLoading, heroID: heroCatalogID)
        cachedCatalogPresentation = (key, value)
        return value
    }
    private(set) var isClearingCache = false
    private(set) var library = LibraryState() {
        didSet { savedTitles = TitleIndex(library.items) }
    }
    /// Answers "is this saved?" for bookmark buttons without scanning the library.
    private var savedTitles = TitleIndex<MediaItem>([])
    private let history = WatchProgressController(
        repository: WatchProgressStorage.repository, loadInBackground: true)
    let trakt = TraktStore()
    let folderSync = FolderSync()
    let simkl = SimklStore()

    var activeTrackingService: TrackingService = TrackingService.current {
        didSet {
            UserDefaults.standard.set(activeTrackingService.rawValue, forKey: "activeTrackingService")
            trakt.pauseTracking()
            simkl.pause()
            Task { await resumeTrakt() }
        }
    }

    var watchProgress: WatchProgress { history.state }

    func isWatched(_ item: MediaItem, episode: Episode? = nil) -> Bool {
        history.isWatched(item, episode: episode)
    }
    var showContinueWatching: Bool {
        didSet { AppPreferenceStorage.saveContinueWatching(showContinueWatching) }
    }
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
    /// Add-ons from another device's sync file that include ones not installed here. Anyone who can
    /// write to the sync folder could add an add-on, so new ones wait for approval.
    private(set) var pendingSyncedAddons: [InstalledAddon]?
    private(set) var tmdbCredential: String?
    private(set) var mdblistKey: String?
    /// Whether a SubDL key is saved, for the Settings status. The key itself is read when needed.
    var subdlConfigured = false
    private(set) var tvdbCredentials: TVDBCredentials?
    private(set) var tvdbRevision = UUID()
    @ObservationIgnored private var tvdbClient: TVDBClient
    @ObservationIgnored private var tvdbCredentialRequest = UUID()
    var metadataConfigurationRevision: String { tmdbRevision.uuidString + tvdbRevision.uuidString }
    func hasMetadata(for item: MediaItem) -> Bool {
        tmdbCredential != nil || (item.type == "series" && tvdbCredentials != nil)
    }
    private(set) var tmdbRevision = UUID()
    @ObservationIgnored private var tmdbClient: TMDBClient
    @ObservationIgnored private var cacheUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCacheUpdates: Set<String> = []
    private var libraryWritable = true
    @ObservationIgnored private let libraryWriter = LibraryWriter(repository: LibraryStorage.repository)
    /// The latest library change; each change waits for the one before it.
    @ObservationIgnored private var librarySave: Task<Void, Never>?
    @ObservationIgnored private var libraryLoad: Task<Void, Never>?
    private var addonsWritable = true

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "VesperMetadata")
    }

    private static func removeRetiredFanartCache() throws {
        let directory = cacheDirectory.appendingPathComponent("Fanart")
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Initialization

    init() {
        let keychain = SecureStorage.snapshot()
        let showAllExternalPlayers = AppPreferenceStorage.showAllExternalPlayers()
        self.showAllExternalPlayers = showAllExternalPlayers
        showSkipIntro = AppPreferenceStorage.showSkipIntro()
        showContinueWatching = AppPreferenceStorage.showContinueWatching()
        playerGestures = AppPreferenceStorage.gestures()
        AppPreferenceStorage.removeRetiredPreferences()
        client = AddonClient(cache: addonCache)
        tmdbClient = TMDBClient(cache: tmdbCache)
        tvdbClient = TVDBClient(cache: tvdbCache)
        let saved: [InstalledAddon]
        do { saved = try keychain.load(.addons) ?? [] } catch {
            saved = []
            addonsWritable = false
            localStorageError = error.localizedDescription
        }
        addons = saved.filter { !AddonPolicy.isCinemeta($0) }
        let players = AppIdentity.detectedPlayers(showAllExternalPlayers: showAllExternalPlayers)
        availablePlayers = players
        let player = AppPreferenceStorage.preferredPlayer().availablePreference(in: players)
        preferredPlayer = player
        AppPreferenceStorage.save(player)
        do { tmdbCredential = try keychain.load(.tmdbCredential) } catch {
            tmdbCredential = nil
            localStorageError = error.localizedDescription
        }
        subdlConfigured = ((try? keychain.load(.subdlAPIKey)) ?? nil) != nil
        do { mdblistKey = try keychain.load(.mdblistKey) } catch {
            mdblistKey = nil
            localStorageError = error.localizedDescription
        }
        do { tvdbCredentials = try keychain.load(.tvdbCredentials) } catch {
            tvdbCredentials = nil
            localStorageError = error.localizedDescription
        }
        if keychain.contains(.retiredFanartCredentials) {
            do { try SecureStorage.delete(.retiredFanartCredentials) } catch {
                localStorageError = error.localizedDescription
            }
        }
        do { try Self.removeRetiredFanartCache() } catch {
            localStorageError = "A retired artwork cache couldn’t be removed."
        }
        do { heroCatalogID = try keychain.load(.heroCatalog) ?? HeroCatalogSelection.automaticID } catch {
            heroCatalogID = HeroCatalogSelection.automaticID
            localStorageError = error.localizedDescription
        }
        do { catalogPreferences = try keychain.load(.catalogPreferences) ?? CatalogPreferences() } catch {
            catalogsWritable = false
            localStorageError = error.localizedDescription
        }
        if saved.count != addons.count {
            do { try SecureStorage.save(addons, for: .addons) } catch {
                localStorageError =
                    "The removed metadata provider couldn’t be cleared from Keychain. It is disabled for this session."
            }
        }
        // Read and decode the library off the main actor so launch isn't held up. Library changes
        // queue behind this load.
        let libraryLoad = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try LibraryStorage.load() }
            }
            .value
            switch result {
            case .success(let loaded):
                self.library = loaded.state
                if loaded.recovered {
                    self.localStorageError =
                        "Your library was recovered from its last saved copy. The damaged file has been preserved."
                }
            case .failure:
                self.libraryWritable = false
                self.localStorageError = "Your saved library couldn’t be read. Its file has been preserved."
            }
        }
        self.libraryLoad = libraryLoad
        librarySave = libraryLoad

        downloads.resolveSource = { [weak self] record in
            guard let self else { throw DownloadFailure.response }
            let candidates: [StreamSource]
            if let id = record.providerID {
                guard let provider = self.enabledAddons.first(where: { $0.id == id }) else {
                    throw DownloadFailure.response
                }
                candidates = try await self.client.streams(
                    provider, type: record.media.type, videoID: record.videoID)
            } else {
                candidates = await self.streamOptions(
                    type: record.media.type, videoID: record.videoID, embedded: nil
                ).options.map(\.source)
                if candidates.isEmpty { return record.source }
            }
            guard let fresh = StreamPolicy.refreshedMatch(for: record.source, in: candidates) else {
                throw DownloadFailure.response
            }
            return fresh
        }
        downloads.start()
    }
    // MARK: - Preferences and hero selection

    var enabledAddons: [InstalledAddon] { addons.filter(\.isEnabled) }

    func refreshPlayers() {
        availablePlayers = AppIdentity.detectedPlayers(showAllExternalPlayers: showAllExternalPlayers)
        let available = preferredPlayer.availablePreference(in: availablePlayers)
        if available != preferredPlayer { preferredPlayer = available }
    }

    var heroCatalogs: [HeroCatalog] { catalogPresentation.heroCatalogs }
    var heroItems: [MediaItem] { catalogPresentation.heroItems }

    func setHeroCatalog(_ id: String) {
        let previous = catalogPreferences.requests(availableCatalogs, heroID: heroCatalogID)
        do {
            try SecureStorage.save(id, for: .heroCatalog)
            heroCatalogID = id
            if previous != catalogPreferences.requests(availableCatalogs, heroID: id) {
                homeCatalogRevision = UUID()
            }
        } catch { localStorageError = error.localizedDescription }
    }

    @discardableResult
    func saveCatalogPreferences(_ proposed: CatalogPreferences) -> Bool {
        guard catalogsWritable else {
            localStorageError = StorageError.unreadable.localizedDescription
            return false
        }
        var proposed = proposed
        proposed.groups = proposed.groups.map {
            CombinedCatalog(
                id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), members: $0.members)
        }
        for (id, var customization) in proposed.customizations {
            customization.name = customization.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if customization.name?.isEmpty == true { customization.name = nil }
            customization.filters = customization.filters.filter { !$0.value.isEmpty }
            proposed.customizations[id] = customization == CatalogCustomization() ? nil : customization
        }
        if proposed.order.isEmpty, (!proposed.customizations.isEmpty || !proposed.groups.isEmpty) {
            proposed.order = catalogs.map(\.id)
        }
        guard proposed != catalogPreferences else { return true }
        do {
            let previous = catalogPreferences.requests(availableCatalogs, heroID: heroCatalogID)
            try SecureStorage.save(proposed, for: .catalogPreferences)
            catalogPreferences = proposed
            catalogLayoutRevision = UUID()
            if previous != proposed.requests(availableCatalogs, heroID: heroCatalogID) {
                homeCatalogRevision = UUID()
            }
            return true
        } catch {
            localStorageError = error.localizedDescription
            return false
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

    /// Add-ons in `synced` that aren't installed here.
    func newSyncedAddons(in synced: [InstalledAddon]) -> [InstalledAddon] {
        let installed = Set(addons.map(\.manifestURL))
        return synced.filter { !installed.contains($0.manifestURL) }
    }

    func acceptSyncedAddons() {
        if let pending = pendingSyncedAddons { saveAddons(pending) }
        pendingSyncedAddons = nil
    }

    /// Keeps this device's add-ons and stops syncing them here, so declining doesn't remove the new
    /// add-ons from the other devices.
    func declineSyncedAddons() {
        pendingSyncedAddons = nil
        folderSync.includesAddons = false
    }

    private func saveAddons(_ updated: [InstalledAddon]) {
        do {
            try SecureStorage.save(updated, for: .addons)
            addons = updated
            Task { await addonCache.clear() }
        } catch { localStorageError = error.localizedDescription }
    }
    // MARK: - MDBList ratings

    func saveMDBListKey(_ input: String) async throws {
        let key = try MDBListClient.normalizedKey(input)
        // Verify before replacing a working saved key.
        try await MDBListClient().validate(key: key)
        try Task.checkCancellation()
        try SecureStorage.save(key, for: .mdblistKey)
        mdblistKey = key
    }

    func removeMDBListKey() throws {
        try SecureStorage.delete(.mdblistKey)
        mdblistKey = nil
    }

    /// IMDb, Rotten Tomatoes and Letterboxd scores for a title, or nil without an MDBList key.
    func ratings(for media: MediaItem, details: MetadataEnrichment?) async -> TitleRatings? {
        guard let key = mdblistKey,
            let title = RatingsTitle(
                type: media.type,
                imdbID: MediaIdentity.validIMDb(media.imdbID) ?? MediaIdentity.validIMDb(details?.imdbID)
                    ?? MediaIdentity.validIMDb(media.id),
                tmdbID: details?.tmdbID ?? media.tmdbID)
        else { return nil }
        return try? await ratingsClient.ratings(for: title, key: key)
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

    func saveTVDBCredentials(apiKey: String, pin: String) async throws {
        let credentials = try TVDBCredentials(apiKey: apiKey, pin: pin)
        let request = UUID()
        tvdbCredentialRequest = request
        let candidate = TVDBClient(cache: tvdbCache)
        try await candidate.validate(credentials: credentials)
        try Task.checkCancellation()
        guard tvdbCredentialRequest == request else { throw CancellationError() }
        try SecureStorage.save(credentials, for: .tvdbCredentials)
        let previous = tvdbClient
        tvdbClient = candidate
        tvdbCredentials = credentials
        tvdbRevision = UUID()
        await previous.invalidate()
    }

    func removeTVDBCredentials() throws {
        try SecureStorage.delete(.tvdbCredentials)
        tvdbCredentialRequest = UUID()
        tvdbCredentials = nil
        let previous = tvdbClient
        tvdbClient = TVDBClient(cache: tvdbCache)
        tvdbRevision = UUID()
        Task { await previous.invalidate() }
    }

    private func withTVDB<Result>(_ operation: (TVDBClient, TVDBCredentials) async throws -> Result)
        async throws -> Result
    {
        guard !isClearingCache else { throw CancellationError() }
        guard let credentials = tvdbCredentials else { throw TVDBError.invalidCredential }
        let revision = metadataConfigurationRevision
        let result = try await operation(tvdbClient, credentials)
        try Task.checkCancellation()
        guard !isClearingCache, metadataConfigurationRevision == revision else { throw CancellationError() }
        return result
    }

    func tmdbPersonID(_ id: Int) async throws -> Int? {
        guard tmdbCredential != nil, tvdbCredentials != nil else { return nil }
        return try await withTVDB { try await $0.tmdbPersonID(id, credentials: $1) }
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
        let previousTVDB = tvdbClient
        tvdbClient = TVDBClient(cache: tvdbCache)
        tmdbClient = TMDBClient(cache: tmdbCache)
        tvdbRevision = UUID()
        var failed = false
        do { try await client.clearCache() } catch { failed = true }
        do { try await previous.clearCache() } catch { failed = true }
        do { try await previousTVDB.clearCache() } catch { failed = true }
        do { try Self.removeRetiredFanartCache() } catch { failed = true }
        do { try await detailPosters.clearCache() } catch { failed = true }
        do { try await introClient.clearCache() } catch { failed = true }
        do { try await ratingsClient.clearCache() } catch { failed = true }
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

    func introSegment(for media: MediaItem, video: VideoSelection, knownEpisodes: [Episode]) async throws
        -> IntroSegment?
    {
        guard showSkipIntro, !isClearingCache, media.type == "series",
            let current = UpNext.currentEpisode(
                media: media, videoID: video.id, episode: video.episode,
                knownEpisodes: knownEpisodes + (media.videos ?? [])),
            let season = current.season, let number = current.episode
        else { return nil }
        let revision = metadataConfigurationRevision
        var identified = media
        if MediaIdentity.validIMDb(media.imdbID) == nil, MediaIdentity.validIMDb(media.id) == nil,
            hasMetadata(for: media), let details = try await enrichedMetadata(for: media)
        {
            identified = details.applying(to: media)
        }
        guard let imdb = MediaIdentity.validIMDb(identified.imdbID) ?? MediaIdentity.validIMDb(identified.id),
            let episode = IntroEpisode(imdbID: imdb, season: season, episode: number)
        else { return nil }
        try Task.checkCancellation()
        guard showSkipIntro, !isClearingCache, revision == metadataConfigurationRevision else {
            throw CancellationError()
        }
        let segment = try await introClient.segment(for: episode)
        try Task.checkCancellation()
        guard showSkipIntro, !isClearingCache, revision == metadataConfigurationRevision else {
            throw CancellationError()
        }
        return segment
    }

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

    func detailArtwork(
        for item: MediaItem, onBackdrop: @MainActor (DetailArtwork) -> Void = { _ in }
    ) async throws -> DetailArtwork {
        guard downloads.networkAvailable else { return downloads.offlineDetailArtwork(for: item) }
        guard hasMetadata(for: item), !isClearingCache else { return DetailArtwork() }
        let revision = metadataConfigurationRevision
        let details = try await enrichedMetadata(for: item)
        try Task.checkCancellation()
        guard revision == metadataConfigurationRevision, !isClearingCache else { throw CancellationError() }
        let backdrop = details?.backdropURL
        if let backdrop { onBackdrop(DetailArtwork(backdropURL: backdrop)) }
        var portrait = details?.textlessPosterURL
        if let candidate = portrait {
            do {
                let textless = try await detailPosters.isTextless(candidate)
                if !textless { portrait = nil }
            } catch is CancellationError { throw CancellationError() } catch { portrait = nil }
        }
        try Task.checkCancellation()
        guard revision == metadataConfigurationRevision, !isClearingCache else { throw CancellationError() }
        let artwork = DetailArtwork(
            textlessPosterURL: portrait,
            backdropURL: details?.backdropURL)
        downloads.rememberDetailArtwork(artwork, for: item)
        return artwork
    }

    func enrichedMetadata(for item: MediaItem) async throws -> MetadataEnrichment? {
        let revision = metadataConfigurationRevision
        let loadTMDB: () async throws -> MetadataEnrichment? = {
            guard self.tmdbCredential != nil else { return nil }
            return try await self.withTMDB { try await $0.enrichment(for: item, credential: $1) }
        }
        let result: MetadataEnrichment?
        if item.type == "series", tvdbCredentials != nil {
            result = try await MetadataResolver.enrichment(
                primary: {
                    var identified = item
                    if MediaIdentity.tvdbID(item) == nil,
                        MediaIdentity.validIMDb(item.imdbID) == nil,
                        MediaIdentity.validIMDb(item.id) == nil,
                        let mapping = try await loadTMDB()
                    {
                        identified = mapping.applying(to: item)
                    }
                    return try await self.withTVDB {
                        try await $0.enrichment(for: identified, credentials: $1)
                    }
                }, fallback: loadTMDB)
        } else {
            result = try await loadTMDB()
        }
        try Task.checkCancellation()
        guard revision == metadataConfigurationRevision else { throw CancellationError() }
        return result
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

    /// TMDB's profile, completed from TheTVDB when a key is set and TMDB leaves gaps.
    func personProfile(personID: Int) async throws -> PersonProfile {
        let profile = try await withTMDB { try await $0.personProfile(personID: personID, credential: $1) }
        let incomplete = profile.biography == nil || profile.birthday == nil || profile.placeOfBirth == nil
        guard incomplete, tvdbCredentials != nil, let tvdbID = profile.tvdbID,
            let details = try? await withTVDB({ try await $0.personDetails(tvdbID, credentials: $1) })
        else { return profile }
        return profile.filling(from: details)
    }

    func episodes(for media: MediaItem, details: MetadataEnrichment, season: Int) async throws -> [Episode] {
        let revision = metadataConfigurationRevision
        if let id = details.tvdbID, tvdbCredentials != nil {
            do {
                let result = try await withTVDB {
                    try await $0.episodes(for: media, id: id, season: season, credentials: $1)
                }
                if !result.isEmpty {
                    if let tmdbID = details.tmdbID, tmdbCredential != nil,
                        result.contains(where: {
                            $0.thumbnail == nil || $0.overview == nil || $0.title == nil
                        }),
                        let backup = try? await withTMDB({
                            try await $0.episodes(for: media, tmdbID: tmdbID, season: season, credential: $1)
                        })
                    {
                        try Task.checkCancellation()
                        guard revision == metadataConfigurationRevision else { throw CancellationError() }
                        return MetadataResolver.episodes(result, fillingFrom: backup)
                    }
                    try Task.checkCancellation()
                    guard revision == metadataConfigurationRevision else { throw CancellationError() }
                    return result
                }
            } catch is CancellationError { throw CancellationError() } catch {
                if details.tmdbID == nil || tmdbCredential == nil { throw error }
            }
        }
        if let id = details.tmdbID, tmdbCredential != nil {
            let result = try await withTMDB {
                try await $0.episodes(for: media, tmdbID: id, season: season, credential: $1)
            }
            guard revision == metadataConfigurationRevision else { throw CancellationError() }
            return result
        }
        return (media.videos ?? []).filter { $0.season == season }
    }

    func recommendations(for details: MetadataEnrichment, page: Int = 1) async throws -> TMDBPage {
        guard let id = details.tmdbID else { throw TMDBError.invalidResponse }
        return try await withTMDB { api, credential in
            try await api.recommendations(
                tmdbID: id, mediaType: details.mediaType, page: page, credential: credential)
        }
    }

    // MARK: - Home and source discovery

    func refresh(preservingUnchanged: Bool = false) async {
        await home.load(
            catalogs: catalogPreferences.requested(availableCatalogs, heroID: heroCatalogID),
            preservingUnchanged: preservingUnchanged
        ) { catalog in
            catalogSource(catalog)
        }
        // The shelf widget can show Home catalogs.
        WidgetPublisher.shared.schedule(store: self)
    }

    func metadata(for item: MediaItem) async -> (MediaItem, String?) {
        // Known metadata identities load through the configured providers; custom IDs retain add-on details.
        if item.id.hasPrefix("tmdb:") || item.id.hasPrefix("tvdb:")
            || item.id.range(of: "^tt[0-9]+$", options: .regularExpression) != nil
        {
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

    func contains(_ item: MediaItem) -> Bool { savedTitles.contains(item) }

    func setWatched(_ watched: Bool, for item: MediaItem, episode: Episode? = nil) {
        let revision = trakt.connectionRevision
        let simklRevision = simkl.connectionRevision
        let simklConnected = simkl.isConnected
        let saved = history.setWatched(watched, for: item, episode: episode)
        let change = TraktHistoryChange(
            media: item, videoID: episode?.watchHistoryID(for: item), action: watched ? .watched : .unwatched)
        Task {
            guard await saved.value else { return }
            if simklConnected, simklRevision == simkl.connectionRevision {
                simkl.setWatched(watched, media: item, videoID: episode?.watchHistoryID(for: item))
                Task { await simkl.synchronize(history: history, force: true) }
            }
            if revision == trakt.connectionRevision { trakt.enqueue(change, history: history) }
        }
        userDataChanged()
    }

    func syncSimkl() async { await simkl.synchronize(history: history, force: true) }

    func connectTrakt() { trakt.startSignIn(history: history) }

    func syncTrakt(force: Bool = false) async { await trakt.synchronize(history: history, force: force) }

    func resumeTrakt() async {
        if activeTrackingService == .trakt { await trakt.resume(history: history) }
        if activeTrackingService == .simkl { await simkl.synchronize(history: history) }
    }

    func refreshTraktWatchedEpisodes(for item: MediaItem) async {
        if activeTrackingService == .trakt { await trakt.refreshWatchedEpisodes(for: item, history: history) }
        if activeTrackingService == .simkl { await simkl.synchronize(history: history) }
    }

    func disconnectTrakt() async { await trakt.disconnect(history: history) }
    func removeFromContinueWatching(_ item: MediaItem) {
        history.removeFromContinueWatching(for: item)
        userDataChanged()
    }

    func recordPlayback(media: MediaItem, video: VideoSelection, update: PlaybackProgressUpdate) {
        history.record(media: media, videoID: video.id, subtitle: video.title, update: update)
        WidgetPublisher.shared.schedule(store: self)
    }

    func scrobble(_ event: TraktScrobbleEvent, media: MediaItem, videoID: String) {
        trakt.receive(event, media: media, videoID: videoID, history: history)
        simkl.receive(event, media: media, videoID: videoID, history: history)
    }

    func flushWatchProgress() async { await history.flush() }

    func toggleLibrary(_ item: MediaItem) {
        commitLibrary { current in
            var proposed = current
            if current.items.contains(where: { $0.isSameTitle(as: item) }) {
                proposed.items.removeAll { $0.isSameTitle(as: item) }
            } else {
                proposed.items.insert(item, at: 0)
            }
            return proposed
        }
    }

    /// Adds a title unless it is already saved.
    func addToLibrary(_ item: MediaItem) {
        commitLibrary { current in
            guard !current.items.contains(where: { $0.isSameTitle(as: item) }) else { return nil }
            var proposed = current
            proposed.items.insert(item, at: 0)
            return proposed
        }
    }

    /// Saves a library change in the background and shows it once it is on disk, so the screen never
    /// shows a change that wasn't saved. `change` starts from the previous change's result, which
    /// keeps quick taps in order; it returns nil to skip saving. Sync merges pass `notify: false`,
    /// since announcing them would only schedule another sync.
    private func commitLibrary(
        notify: Bool = true, _ change: @escaping @MainActor (LibraryState) -> LibraryState?
    ) {
        guard libraryWritable else {
            localStorageError =
                "Your library couldn’t be read. Restore a valid backup before making changes."
            return
        }
        let previous = librarySave
        librarySave = Task {
            await previous?.value
            // A change queued while loading must not overwrite a library that turned out unreadable.
            guard self.libraryWritable else {
                self.localStorageError =
                    "Your library couldn’t be read. Restore a valid backup before making changes."
                return
            }
            guard let proposed = change(self.library) else { return }
            do {
                self.library = try await self.libraryWriter.save(proposed)
                if notify { self.userDataChanged() }
            } catch {
                self.localStorageError = error.localizedDescription
            }
        }
    }

    /// Waits for library changes still being saved.
    func flushLibrary() async { await librarySave?.value }

    /// Returns once saved watch progress and the library have been read. Anything that would act on
    /// them being empty, such as sync, the widgets or a link opened at launch, waits for this first.
    func waitUntilLoaded() async {
        await history.waitUntilLoaded()
        await libraryLoad?.value
    }

    func exportLibrary() throws -> Data {
        guard libraryWritable else { throw LibraryError.unreadable }
        return try LibraryRepository.encode(library)
    }

    // MARK: - Folder sync and widgets

    /// Library or watch state changed: sync soon and refresh the widgets.
    func userDataChanged() {
        folderSync.scheduleSync(store: self)
        WidgetPublisher.shared.schedule(store: self)
    }

    /// What a sync reads from this device. `progressRevision` guards against applying a merge
    /// over a change made while the merge ran.
    var syncState: (library: LibraryState, progress: WatchProgress, progressRevision: Int) {
        (library, history.state, history.revision)
    }

    var syncedSettings: SyncedSettings {
        SyncedSettings(
            showSkipIntro: showSkipIntro, showContinueWatching: showContinueWatching,
            playerGestures: playerGestures,
            subtitleLanguage: UserDefaults.standard.string(forKey: "subdlLanguage"),
            catalogPreferences: catalogPreferences, heroCatalogID: heroCatalogID)
    }

    /// Applies merged sync results, skipping any part that changed locally while the merge ran.
    func applySync(
        library merged: LibraryState, expectedLibrary: LibraryState, progress: WatchProgress,
        progressRevision: Int, settings: SyncedSettings?, addons syncedAddons: [InstalledAddon]?
    ) async {
        if libraryWritable {
            commitLibrary(notify: false) { current in
                current.items == expectedLibrary.items && merged.items != current.items ? merged : nil
            }
            await flushLibrary()
        }
        if progress.records.map(\.id) != history.state.records.map(\.id)
            || progress.records.map(\.updatedAt) != history.state.records.map(\.updatedAt)
            || progress.records.map(\.hiddenFromContinueWatching)
                != history.state.records.map(\.hiddenFromContinueWatching)
        {
            _ = await history.applySynced(progress, ifRevision: progressRevision)
        }
        if let settings, settings != syncedSettings {
            if showSkipIntro != settings.showSkipIntro { showSkipIntro = settings.showSkipIntro }
            if showContinueWatching != settings.showContinueWatching {
                showContinueWatching = settings.showContinueWatching
            }
            if playerGestures != settings.playerGestures { playerGestures = settings.playerGestures }
            if let language = settings.subtitleLanguage {
                UserDefaults.standard.set(language, forKey: "subdlLanguage")
            }
            if catalogPreferences != settings.catalogPreferences {
                saveCatalogPreferences(settings.catalogPreferences)
            }
            if heroCatalogID != settings.heroCatalogID { setHeroCatalog(settings.heroCatalogID) }
        }
        if let syncedAddons, addonsWritable {
            let allowed = syncedAddons.filter { !AddonPolicy.isCinemeta($0) }
            if allowed != addons {
                // Removing, reordering or toggling installed add-ons applies at once.
                if newSyncedAddons(in: allowed).isEmpty {
                    saveAddons(allowed)
                } else {
                    pendingSyncedAddons = allowed
                }
            }
        }
        WidgetPublisher.shared.schedule(store: self)
    }

    func restoreLibrary(_ data: Data) async throws {
        await flushLibrary()
        let restored = try LibraryRepository.decode(data)
        let merged = LibraryRepository.merging(restored, into: library)
        library = try await libraryWriter.save(merged)
        libraryWritable = true
        userDataChanged()
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
