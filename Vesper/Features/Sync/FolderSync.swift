import Foundation
import Observation
import UIKit
import VesperCore

/// Settings that follow the user between devices. Device-specific choices, such as the external
/// player (which depends on installed apps), and all credentials stay local.
struct SyncedSettings: Codable, Equatable {
    var showSkipIntro: Bool
    var showContinueWatching: Bool
    var playerGestures: PlayerGesturePreferences
    var subtitleLanguage: String?
    var catalogPreferences: CatalogPreferences
    var heroCatalogID: String
}

/// Syncs through a folder the user picks, usually in iCloud Drive. Reaching the folder through a
/// security-scoped bookmark needs no iCloud entitlement, so this works however Vesper is signed.
///
/// Each device writes `vesper-<device>.json` and reads every other device's file. Merging is done
/// by `SyncEngine`; see `SyncSnapshot` for the conflict rules.
@MainActor @Observable
final class FolderSync {
    private(set) var folderName: String?
    private(set) var lastSync: Date?
    private(set) var otherDevices: [String] = []
    private(set) var isSyncing = false
    private(set) var error: String?
    var includesAddons: Bool {
        didSet {
            defaults.set(includesAddons, forKey: Keys.includesAddons)
            // Joining adopts the shared add-ons, if any, instead of replacing them with this device's.
            if includesAddons, !oldValue { joiningAddons = true }
        }
    }

    var isEnabled: Bool { folderName != nil }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var joiningAddons = false

    private enum Keys {
        static let bookmark = "syncFolderBookmark"
        static let deviceID = "syncDeviceID"
        static let includesAddons = "syncIncludesAddons"
        static let lastSync = "syncLastDate"
    }

    private nonisolated static let filePrefix = "vesper-"

    private nonisolated static var stateURL: URL {
        LibraryStorage.url.deletingLastPathComponent().appendingPathComponent("sync-state.json")
    }

    init() {
        includesAddons = defaults.bool(forKey: Keys.includesAddons)
        lastSync = defaults.object(forKey: Keys.lastSync) as? Date
        if let folder = resolveFolder() { folderName = folder.lastPathComponent }
    }

    private var deviceID: String {
        if let id = defaults.string(forKey: Keys.deviceID) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Keys.deviceID)
        return id
    }

    // MARK: - Folder

    func chooseFolder(_ url: URL, store: AppStore) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: Keys.bookmark)
            // A different folder holds a different set of devices; start the merge fresh.
            try? FileManager.default.removeItem(at: Self.stateURL)
            folderName = url.lastPathComponent
            otherDevices = []
            error = nil
            syncNow(store: store)
        } catch {
            self.error = "Vesper couldn’t keep access to that folder. Choose it again."
        }
    }

    func stopSyncing() {
        scheduled?.cancel()
        defaults.removeObject(forKey: Keys.bookmark)
        defaults.removeObject(forKey: Keys.lastSync)
        try? FileManager.default.removeItem(at: Self.stateURL)
        folderName = nil
        lastSync = nil
        otherDevices = []
        error = nil
    }

    private func resolveFolder() -> URL? {
        guard let bookmark = defaults.data(forKey: Keys.bookmark) else { return nil }
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let fresh = try? url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            {
                defaults.set(fresh, forKey: Keys.bookmark)
            }
        }
        return url
    }

    // MARK: - Syncing

    /// Coalesces bursts of local changes into one sync a few seconds later.
    func scheduleSync(store: AppStore) {
        guard isEnabled else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self, weak store] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, let store else { return }
            self.syncNow(store: store)
        }
    }

    func syncNow(store: AppStore) {
        guard isEnabled, running == nil else { return }
        scheduled?.cancel()
        running = Task { [weak self, weak store] in
            guard let self, let store else { return }
            // Finish an in-flight sync even if the app moves to the background.
            let background = UIApplication.shared.beginBackgroundTask(withName: "Vesper sync")
            await self.perform(store: store)
            UIApplication.shared.endBackgroundTask(background)
            self.running = nil
        }
    }

    /// Syncs and waits until it finishes, for a background refresh.
    func syncAndWait(store: AppStore) async {
        guard isEnabled else { return }
        syncNow(store: store)
        await running?.value
    }

    private func perform(store: AppStore) async {
        guard let folder = resolveFolder() else {
            error = "The sync folder is no longer available. Choose it again."
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        // Waits for the launch load and pending saves, so a sync never sees an empty library.
        await store.flushWatchProgress()
        await store.flushLibrary()
        let local = store.syncState
        let settings = store.syncedSettings
        let addons = includesAddons ? store.addons : nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var blobs: [String: Data] = [:]
        if let data = try? encoder.encode(settings) { blobs["settings"] = data }
        if let addons, let data = try? encoder.encode(addons) { blobs["addons"] = data }
        let syncedBlobs = blobs
        let joining = joiningAddons, includeAddons = addons != nil
        joiningAddons = false
        let deviceID = deviceID, deviceName = UIDevice.current.model
        let file = folder.appendingPathComponent(Self.filePrefix + deviceID + ".json")

        let outcome = await Task.detached(priority: .utility) {
            () -> Result<(SyncSnapshot, [String], String?), Error> in
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
            do {
                var previous = Self.loadState()
                if joining, let payload = syncedBlobs["addons"] {
                    previous?.blobs["addons"] = SyncBlob(payload: payload, changedAt: .distantPast)
                }
                let snapshot = SyncEngine.localSnapshot(
                    previous: previous, library: local.library, progress: local.progress, blobs: syncedBlobs,
                    deviceID: deviceID, deviceName: deviceName)
                let (remotes, problem) = try Self.readRemotes(in: folder, excluding: file)
                var merged = SyncEngine.merge(local: snapshot, remotes: remotes)
                // With add-ons off, this device's file never carries add-on links.
                if !includeAddons { merged.blobs["addons"] = nil }
                let data = try merged.encoded()
                try Self.coordinatedWrite(data, to: file)
                try SyncSnapshot.writeStateFile(data, to: Self.stateURL)
                return .success((merged, remotes.map(\.deviceName), problem))
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .failure:
            error = "Couldn’t sync with the folder. Check that iCloud Drive is available and try again."
        case .success(let (merged, devices, problem)):
            let syncedSettings = merged.blobs["settings"].flatMap {
                try? JSONDecoder().decode(SyncedSettings.self, from: $0.payload)
            }
            let syncedAddons =
                includesAddons
                ? merged.blobs["addons"].flatMap {
                    try? JSONDecoder().decode([InstalledAddon].self, from: $0.payload)
                }
                : nil
            await store.applySync(
                library: merged.libraryState, expectedLibrary: local.library, progress: merged.watchProgress,
                progressRevision: local.progressRevision, settings: syncedSettings, addons: syncedAddons)
            otherDevices = devices
            error = problem
            let now = Date()
            lastSync = now
            defaults.set(now, forKey: Keys.lastSync)
        }
    }

    // MARK: - Files

    private nonisolated static func loadState() -> SyncSnapshot? {
        guard let data = try? SyncSnapshot.readFile(stateURL) else { return nil }
        return try? SyncSnapshot.decode(data)
    }

    /// Reads every other device's file. Files iCloud hasn't downloaded yet are requested and
    /// picked up by a later sync. Returns a message if any file couldn't be used.
    private nonisolated static func readRemotes(in folder: URL, excluding own: URL) throws -> (
        [SyncSnapshot], String?
    ) {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: folder.path)
        var snapshots: [SyncSnapshot] = [], problem: String?
        for name in names {
            // iCloud placeholders look like ".vesper-<id>.json.icloud".
            if name.hasPrefix("." + filePrefix), name.hasSuffix(".json.icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                try? manager.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
                continue
            }
            guard name.hasPrefix(filePrefix), name.hasSuffix(".json"), name != own.lastPathComponent else {
                continue
            }
            do {
                let data = try coordinatedRead(folder.appendingPathComponent(name))
                snapshots.append(try SyncSnapshot.decode(data))
            } catch let error as SyncError {
                problem = error.localizedDescription
            } catch {
                problem = "One device’s sync file couldn’t be read. It will be retried next time."
            }
        }
        return (snapshots, problem)
    }

    private nonisolated static func coordinatedRead(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            result = Result { try SyncSnapshot.readFile(url) }
        }
        if let coordination { throw coordination }
        return try result.get()
    }

    private nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        var coordination: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) {
            url in
            result = Result { try data.write(to: url, options: .atomic) }
        }
        if let coordination { throw coordination }
        try result.get()
    }
}
