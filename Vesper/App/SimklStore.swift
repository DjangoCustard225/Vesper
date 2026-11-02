import Foundation
import Observation
import VesperCore

@MainActor @Observable
final class SimklStore {
    private(set) var isConnected = false
    private(set) var isAuthorizing = false
    private(set) var deviceCode: SimklDeviceCode?
    var error: String?
    var scrobbling: Bool {
        didSet { UserDefaults.standard.set(scrobbling, forKey: "simklScrobbling") }
    }
    var syncWatched: Bool {
        didSet { UserDefaults.standard.set(syncWatched, forKey: "simklSyncWatched") }
    }
    @ObservationIgnored private let client: SimklClient
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var delivery: Task<Void, Never>?

    init() {
        scrobbling = UserDefaults.standard.object(forKey: "simklScrobbling") as? Bool ?? true
        syncWatched = UserDefaults.standard.object(forKey: "simklSyncWatched") as? Bool ?? true
        var tokens: SimklTokens?
        do { tokens = try SecureStorage.load(.simklTokens) } catch {
            writable = false; self.error = error.localizedDescription
        }
        isConnected = tokens != nil
        let url = LibraryStorage.url.deletingLastPathComponent().appendingPathComponent("simkl-sync.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                state = try SimklSyncRepository(url: url).load()
            } catch { writable = false; self.error = error.localizedDescription }
        }
        client = SimklClient(tokens: tokens) { value in
            if let value {
                try SecureStorage.save(value, for: .simklTokens)
            } else {
                try SecureStorage.delete(.simklTokens)
            }
        }
    }

    var connectionRevision: UUID { revision }
    private(set) var state = SimklSyncState()
    private(set) var isSyncing = false
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var checkedAccount = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var nextSync = Date.distantPast
    private var stateURL: URL {
        LibraryStorage.url.deletingLastPathComponent().appendingPathComponent("simkl-sync.json")
    }
    var enabled: Bool { TrackingService.current == .simkl }

    func suspendSync() { retryTask?.cancel(); syncTask?.cancel() }

    func pause() {
        revision = UUID()
        retryTask?.cancel()
        syncTask?.cancel()
        delivery?.cancel()
    }

    private func save(_ proposed: SimklSyncState) throws {
        guard writable else { throw SimklError.response }
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SimklSyncRepository(url: stateURL).save(proposed)
        state = proposed
    }

    func synchronize(history: WatchProgressController, force: Bool = false) async {
        guard enabled, isConnected, writable, syncWatched, force || Date() >= nextSync else { return }
        if let syncTask { await syncTask.value; return }
        let current = revision
        let task = Task {
            isSyncing = true
            defer { isSyncing = false; syncTask = nil }
            do {
                await delivery?.value
                try Task.checkCancellation()
                if !checkedAccount {
                    let id = try await client.accountID()
                    guard revision == current, enabled else { return }
                    if let old = state.accountID, old != id { try save(SimklSyncState()) }
                    var proposed = state; proposed.accountID = id; try save(proposed)
                    checkedAccount = true
                }
                while let change = state.pending.first {
                    try Task.checkCancellation()
                    guard enabled, revision == current else { return }
                    try await client.setWatched(
                        change.action != .unwatched, media: change.media, videoID: change.videoID)
                    guard enabled, revision == current else { return }
                    var proposed = state; proposed.pending.removeAll { $0.id == change.id };
                    try save(proposed)
                }
                let activities = try await client.get("sync/activities")
                let root = try JSONSerialization.jsonObject(with: activities) as? [String: Any] ?? [:]
                let old =
                    state.activities.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    ?? [:]
                guard let timestamp = root["all"] as? String else { throw SimklError.response }
                var proposed = state
                if state.activities == nil || (old["all"] as? String) != timestamp {
                    for kind in ["shows", "movies"] {
                        var query = [
                            URLQueryItem(name: "extended", value: "full"),
                            URLQueryItem(name: "episode_watched_at", value: "yes"),
                            URLQueryItem(name: "include_all_episodes", value: "yes"),
                        ]
                        if let previous = old["all"] as? String {
                            query.append(URLQueryItem(name: "date_from", value: previous))
                        }
                        let data = try await client.get("sync/all-items/" + kind, query: query)
                        try proposed.apply(data)
                    }
                    if state.activities != nil
                        && String(describing: root["removed_from_list"])
                            != String(describing: old["removed_from_list"])
                    {
                        var retained = SimklSyncState()
                        for kind in ["shows", "movies"] {
                            try retained.apply(
                                await client.get(
                                    "sync/all-items/" + kind,
                                    query: [URLQueryItem(name: "extended", value: "simkl_ids_only")]))
                        }
                        proposed.items = proposed.items.filter { retained.items[$0.key] != nil }
                    }
                }
                guard enabled, revision == current else { return }
                guard
                    await history.mergeSimkl(
                        try proposed.entries(), pending: state.pending,
                        shouldApply: { self.enabled && self.revision == current })
                else { throw SimklError.response }
                guard enabled, revision == current else { return }
                proposed.pending = state.pending
                proposed.activities = activities
                proposed.lastSyncedAt = Date()
                try save(proposed)
                nextSync = Date().addingTimeInterval(60)
                error = nil
            } catch is CancellationError {} catch {
                guard revision == current else { return }
                self.error = error.localizedDescription
                nextSync = Date().addingTimeInterval(60)
                retryTask?.cancel()
                retryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(60)); try Task.checkCancellation() } catch {
                        return
                    }
                    guard let self, self.enabled, self.revision == current else { return }
                    await self.synchronize(history: history)
                }
            }
        }
        syncTask = task
        await task.value
    }

    func startAuthorization() {
        guard authorizationTask == nil, !isConnected, writable else { return }
        authorizationTask = Task {
            await authorize()
            authorizationTask = nil
        }
    }

    func cancelAuthorization() {
        authorizationTask?.cancel()
    }

    private func authorize() async {
        guard writable, !isAuthorizing, !isConnected else { return }
        let current = revision
        isAuthorizing = true
        error = nil
        defer { isAuthorizing = false; deviceCode = nil }
        do {
            let code = try await client.beginAuthorization()
            try Task.checkCancellation()
            guard revision == current else { return }
            deviceCode = code
            try await client.waitForAuthorization(code)
            try Task.checkCancellation()
            guard revision == current else { return }
            isConnected = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func disconnect() async {
        cancelAuthorization()
        revision = UUID()
        delivery?.cancel()
        delivery = nil
        do {
            try await client.disconnect()
            isConnected = false
            checkedAccount = false
            try save(SimklSyncState())
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func receive(
        _ event: TraktScrobbleEvent, media: MediaItem, videoID: String, history: WatchProgressController
    ) {
        guard enabled, isConnected, scrobbling else { return }
        if event.action == .stop, event.progress >= 80 {
            setWatched(true, media: media, videoID: media.type == "series" ? videoID : nil)
        }
        enqueue {
            guard self.scrobbling else { return }
            try await self.client.scrobble(event, media: media, videoID: videoID)
            if event.action == .stop { Task { await self.synchronize(history: history, force: true) } }
        }
    }

    func setWatched(_ watched: Bool, media: MediaItem, videoID: String?) {
        guard enabled, isConnected, syncWatched else { return }
        do {
            var proposed = state
            try proposed.enqueue(
                TraktHistoryChange(media: media, videoID: videoID, action: watched ? .watched : .unwatched))
            try save(proposed)
        } catch { self.error = error.localizedDescription }
    }

    private func enqueue(_ send: @escaping @MainActor () async throws -> Void) {
        let previous = delivery
        let current = revision
        delivery = Task {
            await previous?.value
            guard !Task.isCancelled, revision == current, isConnected, enabled else { return }
            do {
                try await send()
                guard revision == current else { return }
                error = nil
            } catch is CancellationError {} catch {
                guard revision == current else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
