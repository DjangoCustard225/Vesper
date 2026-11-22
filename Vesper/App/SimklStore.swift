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
    @ObservationIgnored private let storage: SimklSyncStorage
    @ObservationIgnored private var stateWork: Task<Void, Error>?
    private(set) var stateLoaded = false
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
        storage = SimklSyncStorage(repository: SimklSyncRepository(url: url))
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
    var enabled: Bool { TrackingService.current == .simkl }

    func suspendSync() { retryTask?.cancel(); syncTask?.cancel() }

    func pause() {
        revision = UUID()
        retryTask?.cancel()
        syncTask?.cancel()
        delivery?.cancel()
    }

    /// Settings can read saved sync information without activating the service or contacting SIMKL.
    func loadState() async {
        let current = revision
        do { try await updateState().value } catch is CancellationError {} catch {
            guard revision == current else { return }
            self.error = error.localizedDescription
        }
    }

    /// Each mutation starts from the last durable state and holds its turn across disk awaits.
    private func updateState(
        _ change: (@MainActor (inout SimklSyncState) throws -> Void)? = nil
    ) -> Task<Void, Error> {
        let previous = stateWork, current = revision
        let task = Task { @MainActor in
            _ = try? await previous?.value
            guard self.revision == current else { throw CancellationError() }
            guard self.writable else { throw SimklError.response }
            if !self.stateLoaded {
                let loaded: SimklSyncState
                do { loaded = try await self.storage.load() } catch { self.writable = false; throw error }
                guard self.revision == current else { throw CancellationError() }
                self.state = loaded
                self.stateLoaded = true
            }
            guard let change else { return }
            var proposed = self.state
            try change(&proposed)
            try await self.storage.save(proposed)
            guard self.revision == current else { throw CancellationError() }
            self.state = proposed
        }
        stateWork = task
        return task
    }

    func synchronize(history: WatchProgressController, force: Bool = false) async {
        guard enabled, isConnected, writable, syncWatched, force || Date() >= nextSync else { return }
        if let syncTask { await syncTask.value; return }
        let current = revision
        let task = Task { [self] in
            isSyncing = true
            defer { isSyncing = false; syncTask = nil }
            do {
                await delivery?.value
                try await updateState().value
                try Task.checkCancellation()
                if !checkedAccount {
                    let id = try await client.accountID()
                    guard revision == current, enabled else { return }
                    try await updateState { proposed in
                        if let old = proposed.accountID, old != id { proposed = SimklSyncState() }
                        proposed.accountID = id
                    }.value
                    guard revision == current, enabled else { return }
                    checkedAccount = true
                }
                let unmatched = try await flushPending(revision: current)
                let update = try await client.historyUpdates(from: state)
                try Task.checkCancellation()
                try await updateState().value
                guard enabled, syncWatched, revision == current else { return }
                guard
                    await history.mergeSimkl(
                        update.entries, pending: state.pending,
                        shouldApply: { self.enabled && self.syncWatched && self.revision == current })
                else { throw SimklError.response }
                guard enabled, syncWatched, revision == current else { return }
                try Task.checkCancellation()
                try await updateState { proposed in
                    proposed.items = update.state.items
                    proposed.activities = update.activities
                    proposed.lastSyncedAt = Date()
                }.value
                guard enabled, syncWatched, revision == current else { return }
                nextSync = Date().addingTimeInterval(60)
                error = unmatched ? SimklError.unidentified.localizedDescription : nil
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

    /// Keep unmatched changes durable without blocking other changes or incoming watch history.
    private func flushPending(revision current: UUID) async throws -> Bool {
        var unmatched = Set<UUID>()
        while let change = state.pending.first(where: { !unmatched.contains($0.id) }) {
            try Task.checkCancellation()
            guard enabled, syncWatched, revision == current else { throw CancellationError() }
            do {
                try await client.setWatched(
                    change.action != .unwatched, media: change.media, videoID: change.videoID)
            } catch SimklError.unidentified {
                unmatched.insert(change.id)
                continue
            }
            try Task.checkCancellation()
            guard enabled, syncWatched, revision == current else { throw CancellationError() }
            try await updateState { $0.pending.removeAll { $0.id == change.id } }.value
        }
        try Task.checkCancellation()
        guard enabled, syncWatched, revision == current else { throw CancellationError() }
        return !unmatched.isEmpty
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
            try await updateState().value
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
        retryTask?.cancel(); retryTask = nil
        syncTask?.cancel()
        delivery?.cancel()
        delivery = nil
        await syncTask?.value
        syncTask = nil
        do {
            try await client.disconnect()
            isConnected = false
            checkedAccount = false
            nextSync = .distantPast
            try await updateState { $0 = SimklSyncState() }.value
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
        let work = updateState { proposed in
            try proposed.enqueue(
                TraktHistoryChange(media: media, videoID: videoID, action: watched ? .watched : .unwatched))
        }
        Task {
            do { try await work.value } catch is CancellationError {} catch {
                self.error = error.localizedDescription
            }
        }
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
