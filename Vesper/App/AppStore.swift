import SwiftUI
import VesperCore

@MainActor
@Observable
final class AppStore {
    let client: AddonClient
    @ObservationIgnored private let addonCache = ResponseCache(directory: AppStore.cacheDirectory.appendingPathComponent("Addons"))
    @ObservationIgnored private let tmdbCache = ResponseCache(directory: AppStore.cacheDirectory.appendingPathComponent("TMDB"))
    var addons: [InstalledAddon]
    var feeds: [CatalogFeed] = []
    var tmdbFeeds: [TMDBFeed] = []
    private(set) var heroCatalogID: String
    var preferredPlayer: VideoPlayer {
        didSet { UserDefaults.standard.set(preferredPlayer.rawValue, forKey: "preferredPlayer") }
    }
    var isLoading = false
    private(set) var library = LibraryState()
    private(set) var watchProgress = WatchProgress()
    var showContinueWatching: Bool {
        didSet { UserDefaults.standard.set(showContinueWatching, forKey: "showContinueWatching") }
    }
    private(set) var cacheChanges = MetadataChanges()
    private(set) var cacheVersions: [String: UUID] = [:]
    var storageError: String?
    var incomingAddon: String?
    var showInstall = false
    private(set) var tmdbCredential: String?
    private(set) var tmdbRevision = UUID()
    @ObservationIgnored private var tmdbClient: TMDBClient
    @ObservationIgnored private var cacheUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCacheUpdates: Set<String> = []
    @ObservationIgnored private var pendingFeedUpdates: Set<String> = []
    private var refreshID = UUID()
    private var libraryWritable = true
    private var watchProgressWritable = true
    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("VesperMetadata")
    }

    init() {
        showContinueWatching = UserDefaults.standard.object(forKey: "showContinueWatching") as? Bool ?? true
        UserDefaults.standard.removeObject(forKey: "automaticallyOpenLastStream")
        client = AddonClient(cache: addonCache)
        tmdbClient = TMDBClient(cache: tmdbCache)
        let saved = SecureStorage.load([InstalledAddon].self, key: "addons") ?? []
        addons = saved.filter { !AddonPolicy.isCinemeta($0) }
        let player = VideoPlayer.preferred(storedValue: UserDefaults.standard.string(forKey: "preferredPlayer"))
        preferredPlayer = player
        UserDefaults.standard.set(player.rawValue, forKey: "preferredPlayer")
        tmdbCredential = SecureStorage.load(String.self, key: "tmdbCredential")
        heroCatalogID = SecureStorage.load(String.self, key: "heroCatalog") ?? HeroCatalogSelection.automaticID
        if saved.count != addons.count {
            do { try SecureStorage.save(addons, key: "addons") }
            catch { storageError = "The removed metadata provider couldn’t be cleared from Keychain. It is disabled for this session." }
        }
        do {
            let loaded = try LibraryStorage.load(); library = loaded.state
            if loaded.recovered { storageError = "Your library was recovered from its last saved copy. The damaged file has been preserved." }
        }
        catch {
            libraryWritable = false
            storageError = "Your saved library couldn’t be read. Its file has been preserved."
        }
        do {
            let loaded = try WatchProgressStorage.repository.load()
            watchProgress = loaded.state
            if loaded.recovered { storageError = "Watch progress was recovered from its last saved copy." }
        } catch {
            watchProgressWritable = false
            storageError = error.localizedDescription
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
        do {
            try SecureStorage.save(updated, key: "addons"); addons = updated
            Task { await addonCache.clear() }
        }
        catch { storageError = error.localizedDescription }
    }
    func saveTMDBCredential(_ input: String) async throws {
        let credential = try TMDBClient.normalizedCredential(input)
        // Verify before replacing a working saved key.
        try await TMDBClient().validate(credential: credential)
        try Task.checkCancellation()
        await tmdbClient.invalidate()
        try Task.checkCancellation()
        try SecureStorage.save(credential, key: "tmdbCredential")
        tmdbClient = TMDBClient(cache: tmdbCache)
        tmdbCredential = credential
        tmdbRevision = UUID()
    }
    func removeTMDBCredential() throws {
        try SecureStorage.delete(key: "tmdbCredential")
        tmdbCredential = nil
        tmdbFeeds = []
        let previous = tmdbClient
        tmdbClient = TMDBClient(cache: tmdbCache)
        Task { await previous.invalidate() }
        tmdbRevision = UUID()
    }
    func metadataRevision(for ids: [String?]) -> String {
        ids.compactMap { $0 }.sorted().compactMap { cacheVersions[$0]?.uuidString }.joined()
    }
    func metadataDidRefresh(_ update: MetadataUpdate) {
        pendingCacheUpdates.insert(update.cacheID)
        cacheUpdateTask?.cancel()
        cacheUpdateTask = Task {
            do { try await Task.sleep(for: .milliseconds(200)); try Task.checkCancellation() }
            catch { return }
            let ids = pendingCacheUpdates; pendingCacheUpdates = []
            for id in ids { cacheVersions[id] = UUID() }
            cacheChanges = MetadataChanges(ids: ids)
            cacheUpdateTask = nil
            await refreshAffectedFeeds(ids)
        }
    }
    private func refreshAffectedFeeds(_ ids: Set<String>) async {
        guard !ids.isEmpty else { return }
        if isLoading { pendingFeedUpdates.formUnion(ids); return }
        let request = refreshID
        let context = addonSignature + tmdbRevision.uuidString
        let sources = tmdbFeeds.map { tmdbSource($0.catalog) } + feeds.map { addonSource($0) }
        let work = sources.enumerated().filter { index, _ in
            let key: String?
            if index < tmdbFeeds.count, let credential = tmdbCredential {
                key = try? MetadataCacheKey.catalog(tmdbFeeds[index].catalog, page: 1, credential: credential)
            } else if index >= tmdbFeeds.count {
                let feed = feeds[index - tmdbFeeds.count]
                key = try? MetadataCacheKey.addonCatalog(feed.addon, feed.catalog, extras: feed.catalog.defaultExtras)
            } else { key = nil }
            return key.map { ids.contains(MetadataCacheKey.id($0)) } ?? false
        }.map { ($0.offset, $0.element) }
        let tmdbCount = tmdbFeeds.count
        await ConcurrentWork.run(work, operation: { job in
            do { return Result<ContentPage, Error>.success(try await job.1.fetch(job.1.initialCursor)) }
            catch { return .failure(error) }
        }) { index, result in
            guard !Task.isCancelled, self.refreshID == request, self.addonSignature + self.tmdbRevision.uuidString == context,
                  case .success(let page) = result else { return }
            let feedIndex = work[index].0
            if feedIndex < tmdbCount { self.tmdbFeeds[feedIndex].items = page.items; self.tmdbFeeds[feedIndex].error = nil }
            else { self.feeds[feedIndex - tmdbCount].items = page.items; self.feeds[feedIndex - tmdbCount].error = nil }
        }
    }
    func identifiedItems(_ items: [MediaItem], resolveUnknown: Bool = true) async -> [MediaItem] {
        guard let credential = tmdbCredential else { return MediaIdentity.unique(items) }
        let revision = tmdbRevision, api = tmdbClient
        var result = items
        await withTaskGroup(of: (Int, MediaItem).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let item = items[index]
                group.addTask {
                    do { return (index, try await api.identified(item, credential: credential, resolveUnknown: resolveUnknown)) }
                    catch { return (index, item) }
                }
            }
            for index in 0..<min(3, items.count) { enqueue(index); next += 1 }
            for await (index, item) in group {
                guard !Task.isCancelled, revision == tmdbRevision else { group.cancelAll(); return }
                result[index] = item
                if next < items.count { enqueue(next); next += 1 }
            }
        }
        guard !Task.isCancelled, revision == tmdbRevision else { return items }
        return MediaIdentity.unique(result)
    }
    // Every TMDB operation uses one credential snapshot and discards results
    // if Settings replaced that credential while a request was in flight.
    private func withTMDB<Result>(_ operation: (TMDBClient, String) async throws -> Result) async throws -> Result {
        guard let credential = tmdbCredential else { throw TMDBError.invalidCredential }
        let revision = tmdbRevision
        let result = try await operation(tmdbClient, credential)
        try Task.checkCancellation()
        guard revision == tmdbRevision else { throw CancellationError() }
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
    nonisolated static func unique(_ items: [MediaItem]) -> [MediaItem] {
        var keys = Set<String>()
        return items.filter { keys.insert($0.key).inserted }
    }
    func episodes(for media: MediaItem, details: TMDBEnrichment, season: Int) async throws -> [Episode] {
        try await withTMDB { try await $0.episodes(for: media, tmdbID: details.id, season: season, credential: $1) }
    }
    func recommendations(for details: TMDBEnrichment, page: Int = 1) async throws -> TMDBPage {
        try await withTMDB { api, credential in
            try await api.recommendations(tmdbID: details.id, mediaType: details.mediaType, page: page, credential: credential)
        }
    }
    func refresh() async {
        let request = UUID(); refreshID = request
        let context = addonSignature + tmdbRevision.uuidString
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
        let sources = tmdbCandidates.map { tmdbSource($0.catalog) } + candidates.map { addonSource($0) }
        await ConcurrentWork.run(sources, operation: { source in
            do { return Result<ContentPage, Error>.success(try await source.fetch(source.initialCursor)) }
            catch { return .failure(error) }
        }) { index, response in
            guard self.refreshID == request, !Task.isCancelled, self.addonSignature + self.tmdbRevision.uuidString == context else { return }
            let items: [MediaItem]?, failure: String?
            switch response {
            case .success(let page): items = page.items; failure = nil
            case .failure(let error):
                if error is CancellationError { return }
                items = nil; failure = error.localizedDescription
            }
            if index < tmdbCandidates.count {
                if let items { tmdbResult[index].items = items }
                tmdbResult[index].error = failure; self.tmdbFeeds = tmdbResult
            } else {
                if let items { result[index - tmdbCandidates.count].items = items }
                result[index - tmdbCandidates.count].error = failure; self.feeds = result
            }
        }
        guard refreshID == request else { return }
        isLoading = false
        guard !Task.isCancelled, addonSignature + tmdbRevision.uuidString == context else { return }
        feeds = result
        tmdbFeeds = tmdbResult
        let updates = pendingFeedUpdates; pendingFeedUpdates = []
        await refreshAffectedFeeds(updates)
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
    func streamOptions(type: String, videoID: String, embedded: [StreamSource]?, onUpdate: (@MainActor (StreamResults) -> Void)? = nil) async -> StreamResults {
        if let embedded { return StreamResults(options: embedded.map { StreamOption(addonName: "Included source", source: $0) }).playable() }
        let providers = enabledAddons.filter { $0.manifest.supports("stream", type: type, id: videoID) }
        var results: [(Int, [StreamOption], String?)] = []
        await ConcurrentWork.run(providers, operation: { [client] addon in
            do {
                let sources = try await client.streams(addon, type: type, videoID: videoID)
                return (sources.map { StreamOption(addonName: addon.manifest.name, source: $0, provider: addon) }, Optional<String>.none)
            } catch is CancellationError { return ([], Optional<String>.none) }
            catch { return ([], Optional(addon.manifest.name + ": " + error.localizedDescription)) }
        }) { index, response in
            guard !Task.isCancelled else { return }
            results.append((index, response.0, response.1))
            let ordered = results.sorted { $0.0 < $1.0 }
            onUpdate?(StreamResults(options: ordered.flatMap(\.1), failures: ordered.compactMap(\.2)).playable())
        }
        let ordered = results.sorted { $0.0 < $1.0 }
        return StreamResults(options: ordered.flatMap(\.1), failures: ordered.compactMap(\.2)).playable()
    }
    func freshSource(_ option: StreamOption, type: String, videoID: String) async throws -> StreamSource {
        try await StreamPolicy.freshSource(option.source, fetchedAt: option.fetchedAt) {
            if let provider = option.provider {
                guard enabledAddons.contains(where: { $0.id == provider.id }) else { throw PlaybackError.sourceChanged }
                return try await client.streams(provider, type: type, videoID: videoID)
            }
            return await streamOptions(type: type, videoID: videoID, embedded: nil).options.map(\.source)
        }
    }
    func contains(_ item: MediaItem) -> Bool { library.items.contains { $0.isSameTitle(as: item) } }
    func setWatched(_ watched: Bool, for item: MediaItem) {
        guard watchProgressWritable else {
            storageError = "Saved watch progress couldn’t be read. Its files have been preserved."
            return
        }
        var proposed = watchProgress
        proposed.setWatched(watched, for: item)
        commitWatchProgress(proposed)
    }
    func recordPlayback(media: MediaItem, video: VideoSelection, update: PlaybackProgressUpdate) {
        var proposed = watchProgress
        guard proposed.record(media: media, videoID: video.id, subtitle: video.title,
                              elapsed: update.elapsed, duration: update.duration, ended: update.ended) else { return }
        commitWatchProgress(proposed)
    }
    private func commitWatchProgress(_ proposed: WatchProgress) {
        guard watchProgressWritable else { return }
        do {
            try WatchProgressStorage.repository.save(proposed)
            watchProgress = proposed
        } catch { storageError = error.localizedDescription }
    }
    func toggleLibrary(_ item: MediaItem) {
        var proposed = library
        if contains(item) { proposed.items.removeAll { $0.isSameTitle(as: item) } }
        else { proposed.items.insert(item, at: 0) }
        commitLibrary(proposed)
    }
    private func commitLibrary(_ proposed: LibraryState) {
        guard libraryWritable else { storageError = "Your library couldn’t be read. Restore a valid backup before making changes."; return }
        do { try LibraryStorage.repository.commit(proposed, current: &library) }
        catch { storageError = error.localizedDescription }
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
    var errorDescription: String? { "TMDB provides movie and series metadata. Add streaming, subtitle, or other catalog add-ons instead." }
}
