import Foundation
import Observation
import VesperCore

@MainActor @Observable
final class TraktStore {
    private(set) var isConnected = false
    private(set) var isAuthorizing = false
    private(set) var isSyncing = false
    private(set) var needsReconnect = false
    private(set) var deviceCode: TraktDeviceCode?
    private(set) var state = TraktSyncState()
    var error: String?
    var syncHistory: Bool {
        didSet { UserDefaults.standard.set(syncHistory, forKey: "traktSyncHistory") }
    }
    private(set) var scrobbleError: String?
    @ObservationIgnored private let scrobbleDelivery = TraktScrobbleDelivery()
    var scrobbling: Bool {
        didSet {
            UserDefaults.standard.set(scrobbling, forKey: "traktScrobbling")
            if !scrobbling { scrobbleDelivery.cancel(); scrobbleError = nil }
        }
    }
    @ObservationIgnored private let client: TraktClient
    @ObservationIgnored private let repository: TraktStateRepository
    @ObservationIgnored private var writable = true
    @ObservationIgnored private var checkedAccount = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var active = true
    @ObservationIgnored private var nextAttempt = Date.distantPast
    @ObservationIgnored private var retryDelay: TimeInterval = 15
    @ObservationIgnored private var rateLimitedUntil = Date.distantPast
    @ObservationIgnored private var watchedProgressRefreshes: [String: Date] = [:]
    @ObservationIgnored private var watchedProgressInFlight = Set<String>()

    var connectionRevision: UUID { generation }

    init() {
        syncHistory = UserDefaults.standard.object(forKey: "traktSyncHistory") as? Bool ?? true
        scrobbling = UserDefaults.standard.object(forKey: "traktScrobbling") as? Bool ?? true
        let repository = TraktStateRepository(
            url: LibraryStorage.url.deletingLastPathComponent().appendingPathComponent("trakt-sync.json"))
        self.repository = repository
        do { state = try repository.load() } catch {
            writable = false
            self.error = error.localizedDescription
        }
        var tokens: TraktTokens?
        do { tokens = try SecureStorage.load(.traktTokens) } catch {
            writable = false
            self.error = error.localizedDescription
        }
        isConnected = tokens != nil
        client = TraktClient(tokens: tokens) { value in
            if let value {
                try SecureStorage.save(value, for: .traktTokens)
            } else {
                try SecureStorage.delete(.traktTokens)
            }
        }
    }

    func startSignIn(history: WatchProgressController) {
        guard !isAuthorizing, writable else { return }
        syncTask?.task.cancel()
        scrobbleDelivery.cancel()
        scrobbleError = nil
        retryTask?.cancel()
        generation = UUID()
        error = nil
        isAuthorizing = true
        let revision = generation
        authorizationTask = Task {
            defer { self.isAuthorizing = false; self.deviceCode = nil; self.authorizationTask = nil }
            do {
                if isConnected {
                    try await client.disconnect()
                    isConnected = false
                }
                let code = try await client.beginAuthorization()
                try Task.checkCancellation()
                guard generation == revision else { return }
                deviceCode = code
                let deadline = Date().addingTimeInterval(Double(code.expiresIn))
                var interval = Double(code.interval)
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    guard Date() < deadline else { throw TraktError.authorizationExpired }
                    do {
                        if try await client.pollAuthorization(code) {
                            isConnected = true
                            needsReconnect = false
                            checkedAccount = false
                            try await establishAccount(history: history, revision: revision)
                            await synchronize(history: history, force: true)
                            return
                        }
                    } catch TraktError.rateLimited(let delay) { interval = max(interval + 1, delay) }
                }
                throw TraktError.authorizationExpired
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    func cancelSignIn() {
        authorizationTask?.cancel()
        Task { await client.cancelAuthorization() }
    }

    func resume(history: WatchProgressController) async {
        active = true
        await synchronize(history: history)
    }

    func refreshWatchedEpisodes(for media: MediaItem, history: WatchProgressController) async {
        guard isConnected, syncHistory, !needsReconnect, writable, Date() >= rateLimitedUntil,
            media.type == "series"
        else { return }
        let revision = generation
        do {
            try await establishAccount(history: history, revision: revision)
            guard generation == revision, isConnected, syncHistory else { return }
            let identity = MediaIdentity.aliases(media).sorted().first ?? media.key
            let key = "\(state.account?.id ?? "unknown"): \(identity)"
            if let lastRefresh = watchedProgressRefreshes[key],
                Date().timeIntervalSince(lastRefresh) < 300
            {
                return
            }
            guard watchedProgressInFlight.insert(key).inserted else { return }
            defer { watchedProgressInFlight.remove(key) }
            let entries = try await client.watchedEpisodes(for: media)
            guard generation == revision, isConnected, syncHistory else { return }
            let applied = await history.replaceTraktHistory(
                for: media, with: entries, pending: state.pending,
                shouldApply: {
                    self.generation == revision && self.isConnected && self.syncHistory
                })
            guard applied, generation == revision else { return }
            if watchedProgressRefreshes.count >= 128 {
                for (oldKey, _) in watchedProgressRefreshes.sorted(by: { $0.value < $1.value }).prefix(32) {
                    watchedProgressRefreshes.removeValue(forKey: oldKey)
                }
            }
            watchedProgressRefreshes[key] = Date()
        } catch is CancellationError {
        } catch {
            // Keep saved episode status available when Trakt cannot be reached.
        }
    }

    func suspend() {
        active = false
        retryTask?.cancel()
        retryTask = nil
    }

    func disconnect(history: WatchProgressController) async {
        cancelSignIn()
        syncTask?.task.cancel()
        scrobbleDelivery.cancel()
        scrobbleError = nil
        retryTask?.cancel()
        generation = UUID()
        do {
            try await client.disconnect()
            isConnected = false
            needsReconnect = false
            checkedAccount = false
            nextAttempt = .distantPast
            retryDelay = 15
            await history.detachTrakt()
            try repository.reset()
            state = TraktSyncState()
            writable = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func enqueue(_ change: TraktHistoryChange, history: WatchProgressController) {
        guard isConnected, syncHistory else { return }
        do {
            var proposed = state
            try proposed.enqueue(change)
            try commit(proposed)
            Task { await synchronize(history: history, force: true) }
        } catch { self.error = error.localizedDescription }
    }

    func discard(_ id: UUID) {
        do { try acknowledge(id) } catch { self.error = error.localizedDescription }
    }

    func synchronize(history: WatchProgressController, force: Bool = false) async {
        guard isConnected, !needsReconnect, writable else { return }
        guard Date() >= rateLimitedUntil else { return }
        if let syncTask { await syncTask.task.value; return }
        guard force || Date() >= nextAttempt else { return }
        let revision = generation, id = UUID()
        let task = Task { [self] in
            isSyncing = true
            defer {
                if syncTask?.id == id { syncTask = nil }
                isSyncing = false
            }
            do {
                // A queued stop must never overtake its corresponding start or pause event.
                await scrobbleDelivery.flush()
                try Task.checkCancellation()
                try await establishAccount(history: history, revision: revision)
                var changed = false
                var unmatched = Set<UUID>()
                while let change = state.pending.first(where: { eligible($0) && !unmatched.contains($0.id) })
                {
                    do { try await client.apply(change) } catch TraktError.unidentifiedTitle {
                        unmatched.insert(change.id)
                        continue
                    }
                    try Task.checkCancellation()
                    guard generation == revision else { return }
                    try acknowledge(change.id)
                    if change.action == .stopped { scrobbleError = nil }
                    changed = true
                }
                if syncHistory {
                    let snapshot = try await client.watched(
                        previousFingerprint: force || changed ? nil : state.fingerprint)
                    try Task.checkCancellation()
                    guard generation == revision, isConnected, syncHistory else { return }
                    if let snapshot {
                        guard
                            await history.mergeTrakt(
                                snapshot.entries, pending: state.pending,
                                shouldApply: {
                                    self.generation == revision && self.isConnected && self.syncHistory
                                })
                        else { throw WatchProgressError.writeFailed }
                        guard generation == revision else { return }
                        var proposed = state
                        proposed.fingerprint = snapshot.fingerprint
                        try commit(proposed)
                    }
                }
                var proposed = state
                proposed.lastSyncedAt = Date()
                try commit(proposed)
                error =
                    unmatched.isEmpty
                    ? nil : "Some titles couldn’t be matched to Trakt. Review your unsent changes."
                retryDelay = 15
                nextAttempt = Date().addingTimeInterval(60)
            } catch is CancellationError {} catch {
                guard generation == revision else { return }
                handle(error, history: history)
            }
        }
        syncTask = (id, task)
        await task.value
    }

    private func establishAccount(history: WatchProgressController, revision: UUID) async throws {
        guard !checkedAccount else { return }
        let account = try await client.account()
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        if let previous = state.account, previous.id != account.id {
            // Unsent changes are bound to their originating account and can never cross into another.
            await history.detachTrakt()
            try commit(TraktSyncState())
        }
        var proposed = state
        proposed.account = account
        try commit(proposed)
        checkedAccount = true
    }

    private func eligible(_ change: TraktHistoryChange) -> Bool {
        if change.action == .stopped { return scrobbling }
        return syncHistory
    }

    private func acknowledge(_ id: UUID) throws {
        var proposed = state
        proposed.pending.removeAll { $0.id == id }
        proposed.fingerprint = nil
        try commit(proposed)
    }

    private func commit(_ proposed: TraktSyncState) throws {
        guard writable else { throw TraktStateError.unreadable }
        try repository.save(proposed)
        state = proposed
    }

    private func handle(_ failure: Error, history: WatchProgressController) {
        error = failure.localizedDescription
        if failure as? TraktError == .reconnect {
            needsReconnect = true
            return
        }
        if failure as? TraktError == .accountLimit
            || failure as? TraktError == .historyLimitReached
            || failure as? TraktError == .unidentifiedTitle
        {
            return
        }
        let delay: TimeInterval
        if case TraktError.rateLimited(let seconds) = failure {
            delay = seconds
            rateLimitedUntil = Date().addingTimeInterval(seconds)
        } else {
            delay = retryDelay; retryDelay = min(300, retryDelay * 2)
        }
        nextAttempt = Date().addingTimeInterval(delay)
        guard active else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() } catch { return }
            guard let self, self.active else { return }
            await self.synchronize(history: history, force: true)
        }
    }

    func receive(
        _ event: TraktScrobbleEvent, media: MediaItem, videoID: String, history: WatchProgressController
    ) {
        guard isConnected, scrobbling, WatchProgress.supports(media) else { return }
        let revision = generation
        let change = TraktHistoryChange(
            id: event.sessionID, media: media, videoID: videoID, action: .stopped, progress: event.progress)
        let completed = event.action == .stop && event.progress > 80
        if completed {
            do {
                var proposed = state
                try proposed.enqueue(change)
                try commit(proposed)
            } catch { scrobbleError = error.localizedDescription; return }
        }
        scrobbleDelivery.submit(event) { [weak self] in
            guard let self, self.generation == revision, self.isConnected, self.scrobbling,
                !self.needsReconnect
            else { throw CancellationError() }
            if Date() < self.rateLimitedUntil {
                throw TraktError.rateLimited(self.rateLimitedUntil.timeIntervalSinceNow)
            }
            try await self.establishAccount(history: history, revision: revision)
            if completed {
                try await self.client.apply(change)
                guard self.generation == revision else { throw CancellationError() }
                try self.acknowledge(change.id)
            } else {
                try await self.client.scrobble(
                    event.action, media: media, videoID: videoID, progress: event.progress)
            }
        } succeeded: { [weak self] in
            guard let self, self.generation == revision else { return }
            self.scrobbleError = nil
            if event.action == .stop {
                Task { await self.synchronize(history: history, force: true) }
            }
        } failed: { [weak self] failure in
            guard let self, self.generation == revision else { return }
            self.scrobbleError = failure.localizedDescription
            if failure as? TraktError == .reconnect { self.needsReconnect = true }
            if case TraktError.rateLimited(let seconds) = failure {
                self.rateLimitedUntil = Date().addingTimeInterval(seconds)
            }
            // Durable completions are reconciled after transient delivery has finished retrying.
            if completed {
                Task { await self.synchronize(history: history, force: true) }
            }
        }
    }
}
