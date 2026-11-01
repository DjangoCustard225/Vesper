import Foundation
import Network
import UIKit
import UserNotifications
import Observation
import VesperCore
import UsenetEngine

@MainActor @Observable final class DownloadManager {
    static let shared = DownloadManager()
    static let sessionID = "app.vesper.downloads"
    private(set) var library = DownloadLibrary()
    private(set) var disk = DownloadDiskState()
    var error: String?
    private(set) var networkAvailable = false
    private(set) var networkStatusKnown = false
    private(set) var cellularNetwork = false
    private var fileLeases = DownloadFileLeases()
    var protectedIDs: Set<UUID> { fileLeases.ids }
    @ObservationIgnored var resolveSource: (@MainActor (DownloadRecord) async throws -> StreamSource)?
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private let storage = DownloadStorage(root: DownloadFiles.root)
    @ObservationIgnored private var writable = false
    @ObservationIgnored private var recovered = false
    @ObservationIgnored private var operationTail: Task<Void, Never>?
    @ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var preparations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var artworkTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var detailArtworkSnapshots: [String: DetailArtwork] = [:]
    @ObservationIgnored private var progressValues: [UUID: DownloadProgress] = [:]
    @ObservationIgnored private var lastCheckpoint: [UUID: Date] = [:]
    @ObservationIgnored private var appBackground = UIApplication.shared.applicationState == .background
    @ObservationIgnored private var backgroundStopping = false
    @ObservationIgnored private var usenetPlaybackReservation: UUID?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var httpWatchdog: Task<Void, Never>?
    @ObservationIgnored private var httpActivity: [UUID: (bytes: Int64, time: TimeInterval)] = [:]
    @ObservationIgnored private var httpWaiting = Set<UUID>()
    @ObservationIgnored private var retryWake: Task<Void, Never>?
    @ObservationIgnored private var policyPauses: Set<UUID> = []
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let delegate = DownloadSessionDelegate()
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false; config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true; config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
    }()
    @ObservationIgnored private lazy var background: DownloadBackgroundCoordinator = {
        let coordinator = DownloadBackgroundCoordinator(scheduler: NativeDownloadBackgroundScheduler())
        coordinator.onPermissionChange = { [weak self] in
            self?.submit { await self?.drive() }
        }
        coordinator.onStop = { [weak self] in await self?.stopBackgroundDownloads() }
        return coordinator
    }()
    var backgroundStatus: String? { background.status }
    private var canExecuteInProcess: Bool { !appBackground || background.isGranted }
    private func backgroundItems() -> [DownloadBackgroundItem] {
        records.map { record in
            let value = progressValues[record.id]
            return DownloadBackgroundItem(
                id: record.id, title: record.media.name, phase: record.phase,
                bytes: value?.bytes ?? record.receivedBytes, total: value?.total ?? record.expectedBytes,
                work: value?.work, message: record.message, speed: value?.currentSpeed ?? 0)
        }
    }
    private func refreshBackground(force: Bool = false) {
        background.update(items: backgroundItems(), force: force)
    }
    private func requestBackground() {
        guard !appBackground else { return }
        background.request(items: backgroundItems())
    }
    private init() {
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied, cellular = path.usesInterfaceType(.cellular)
            DispatchQueue.main.async {
                let manager = DownloadManager.shared
                manager.submit {
                    manager.networkAvailable = available; manager.cellularNetwork = cellular
                    manager.networkStatusKnown = true
                    manager.resumeArtwork(); await manager.drive()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.vesper.download-network"))
    }
    /// A command holds its turn across storage awaits. Network preparation runs outside this queue.
    private func schedule<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) -> Task<
        T, Error
    > {
        let previous = operationTail
        let task = Task { @MainActor in
            await previous?.value; return try await operation()
        }
        operationTail = Task { _ = try? await task.value }
        return task
    }
    private func submit(_ operation: @escaping @MainActor () async -> Void) { _ = schedule(operation) }
    var records: [DownloadRecord] { library.records }
    var allowsCellular: Bool { library.allowsCellular }
    var canTransfer: Bool { networkAvailable && (!cellularNetwork || allowsCellular) }
    var completed: [DownloadRecord] { records.filter { $0.phase == .completed } }
    var usedBytes: Int64 { disk.savedBytes }
    var partialBytes: Int64 {
        max(
            disk.incomingBytes,
            records.filter { $0.phase != .completed }.reduce(0) {
                $0 + (progressValues[$1.id]?.bytes ?? $1.receivedBytes)
            })
    }
    func progress(for record: DownloadRecord) -> DownloadProgress {
        if let value = progressValues[record.id] { return value }
        let value = DownloadProgress(); value.reset(bytes: record.receivedBytes, total: record.expectedBytes)
        progressValues[record.id] = value; return value
    }
    func start() { submit { await self.recover() } }
    func ready() async {
        _ = try? await schedule { if !self.recovered { await self.recover() } }.value
    }
    private func recover() async {
        do {
            if !writable { library = try await storage.load(); writable = true; error = nil }
            if !recovered {
                try? FileManager.default.removeItem(
                    at: DownloadFiles.root.appendingPathComponent("UsenetTemporary", isDirectory: true))
                let existing = await session.allTasks
                library = try await storage.recover(library)
                disk = await storage.diskState()
                var proposed = library, retained = Set<UUID>()
                for task in existing {
                    guard let task = task as? URLSessionDownloadTask,
                        let key = DownloadTaskKey(task.taskDescription),
                        let index = proposed.records.firstIndex(where: {
                            $0.id == key.id && $0.attempt == key.attempt
                        }),
                        proposed.records[index].phase.isActive
                    else { task.cancel(); continue }
                    retained.insert(key.id); tasks[key.id] = task
                    if proposed.records[index].phase == .pausing {
                        Task {
                            let data = await task.cancelByProducingResumeData();
                            self.submit { await self.paused(key, data: data) }
                        }
                    } else {
                        proposed.records[index].phase = .downloading
                        httpActivity[key.id] = (
                            proposed.records[index].receivedBytes, ProcessInfo.processInfo.systemUptime
                        )
                        task.resume()
                    }
                }
                for index in proposed.records.indices {
                    let record = proposed.records[index]
                    proposed.records[index] = DownloadPolicy.recovered(
                        record, hasTask: retained.contains(record.id), hasFile: fileURL(record) != nil)
                }
                guard await commit(proposed) else { return }
                recovered = true
                await storage.reconcile(library)
            } else {
                library = try await storage.recover(library)
            }
            disk = await storage.diskState()
            var proposed = library
            var changed = false
            for index in proposed.records.indices {
                let record = proposed.records[index]
                let hasTask = tasks[record.id] != nil || preparations[record.id] != nil
                if (record.phase.isActive && !hasTask)
                    || (record.phase == .completed && fileURL(record) == nil)
                {
                    proposed.records[index] = DownloadPolicy.recovered(
                        record, hasTask: hasTask, hasFile: fileURL(record) != nil)
                    changed = true
                }
            }
            if changed, !(await commit(proposed)) { return }
            await linkSharedArtwork()
            resumeArtwork(); startHTTPWatchdog(); await drive()
        } catch {
            self.error =
                (error as? DownloadFailure)?.localizedDescription
                ?? "Downloads could not be restored. Your files have been preserved."
        }
    }
    @discardableResult private func commit(_ proposed: DownloadLibrary) async -> Bool {
        guard writable else { return false }
        do {
            try await storage.save(proposed); library = proposed; refreshBackground(force: true); return true
        } catch {
            self.error = "Changes to downloads could not be saved. Your existing files have been preserved.";
            return false
        }
    }
    @discardableResult private func change(_ id: UUID, _ edit: (inout DownloadRecord) -> Void) async -> Bool {
        var proposed = library
        guard let index = proposed.records.firstIndex(where: { $0.id == id }) else { return false }
        edit(&proposed.records[index]); return await commit(proposed)
    }
    func enqueue(media: MediaItem, video: VideoSelection, option: StreamOption) async throws {
        try await schedule { try await self.add(media: media, video: video, option: option) }.value
    }
    private func add(media: MediaItem, video: VideoSelection, option: StreamOption) async throws {
        let live = media.type == "tv" || media.behaviorHints?.isLive == true
        if !DownloadPolicy.supportsUsenet(option.source, live: live) {
            _ = try DownloadPolicy.url(for: option.source, live: live)
        }
        if !writable { await recover() }
        guard writable else { throw DownloadFailure.unreadable }
        var record = DownloadRecord(
            media: media, videoID: video.id, subtitle: video.title, episode: video.episode,
            source: option.source, providerID: option.provider?.id, fetchedAt: option.fetchedAt)
        record.httpParallel =
            !DownloadPolicy.supportsUsenet(option.source) && HTTPDownloadOptions.shared.parallel
        record.detailArtwork = MediaIdentity.aliases(media).compactMap { detailArtworkSnapshots[$0] }.first
        for raw in record.artworkURLs {
            if let url = localArtwork(raw, record: record) { record.artwork[raw] = url.lastPathComponent }
        }
        if let existing = records.first(where: { $0.duplicates(record) }) {
            if existing.phase == .failed || existing.phase == .paused { await resume(existing.id) }; return
        }
        var proposed = library; proposed.records.append(record)
        guard await commit(proposed) else { throw DownloadFailure.unreadable }
        requestBackground(); resumeArtwork(); await drive()
    }
    func setCellular(_ enabled: Bool) {
        submit {
            var proposed = self.library; proposed.allowsCellular = enabled
            guard await self.commit(proposed) else { return }
            for record in self.records where record.phase.isActive {
                self.policyPauses.insert(record.id); await self.pause(record.id)
            }
            await self.drive()
        }
    }
    func requestPause(_ id: UUID) { submit { await self.pause(id) } }
    func requestResume(_ id: UUID) { submit { await self.resume(id) } }
    func requestRemove(_ ids: Set<UUID>) { submit { await self.remove(ids) } }
    private func pause(_ id: UUID) async {
        guard let record = records.first(where: { $0.id == id }), record.phase != .completed else { return }
        guard let task = tasks[id] else {
            if DownloadPolicy.supportsUsenet(record.source) || record.httpParallel == true,
                let preparation = preparations[id]
            {
                guard record.phase != .pausing else { return }
                guard
                    await change(
                        id,
                        {
                            $0.phase = .pausing; $0.receivedBytes = progress(for: record).bytes
                        })
                else { return }
                preparation.cancel()
                return
            }
            let automatic = policyPauses.remove(id) != nil
            guard
                await change(
                    id,
                    {
                        $0.phase = automatic ? .queued : .paused
                        $0.receivedBytes = progress(for: record).bytes
                    })
            else { return }
            preparations[id]?.cancel(); preparations[id] = nil
            await drive(); return
        }
        guard record.phase != .pausing, await change(id, { $0.phase = .pausing }) else { return }
        let key = DownloadTaskKey(id: id, attempt: record.attempt)
        Task {
            let data = await task.cancelByProducingResumeData();
            self.submit { await self.paused(key, data: data) }
        }
    }
    private func paused(_ key: DownloadTaskKey, data: Data?) async {
        guard let record = matching(key), [.pausing, .paused, .queued].contains(record.phase) else { return }
        if let receipt = await storage.stagedReceipt(key) { await finished(key, receipt: receipt); return }
        tasks[key.id] = nil; httpActivity[key.id] = nil; httpWaiting.remove(key.id)
        let auto = policyPauses.remove(key.id) != nil
        _ = await change(key.id) {
            if let data { $0.resumeData = data }; $0.receivedBytes = progress(for: record).bytes
            $0.phase = auto ? .queued : (record.phase == .queued ? .queued : .paused)
            $0.message = record.message == DownloadFailure.storage.localizedDescription ? record.message : nil
        }
        await drive()
    }
    private func resume(_ id: UUID) async {
        guard let record = records.first(where: { $0.id == id }), [.paused, .failed].contains(record.phase)
        else { return }
        _ = await change(id) {
            $0.phase = .queued; $0.message = nil; $0.retryCount = 0; $0.retryAt = nil
            $0.httpResumeRecoveries = 0; $0.httpAuthRetries = 0
        }
        requestBackground(); await drive()
    }
    private func drive() async {
        refreshBackground(force: true)
        guard recovered, writable, !backgroundStopping else { return }
        for record in records where record.phase.isActive && record.phase != .pausing {
            let usenet = DownloadPolicy.supportsUsenet(record.source)
            let inProcess = usenet || record.httpParallel == true || preparations[record.id] != nil
            if (inProcess && (!canTransfer || !canExecuteInProcess))
                || (usenet && usenetPlaybackReservation != nil)
            {
                policyPauses.insert(record.id); await pause(record.id)
            }
        }
        updateUsenetIdleTimer()
        guard canTransfer else { return }
        retryWake?.cancel(); retryWake = nil
        let usenetActive = records.contains { $0.phase.isActive && DownloadPolicy.supportsUsenet($0.source) }
        var reservedUsenet = usenetActive
        let eligible = records.filter { record in
            guard record.phase == .queued else { return true }
            guard canExecuteInProcess else { return false }
            guard DownloadPolicy.supportsUsenet(record.source) else { return true }
            guard usenetPlaybackReservation == nil, !reservedUsenet else { return false }
            reservedUsenet = true; return true
        }
        for record in DownloadPolicy.next(eligible) { await prepare(record) }
        if let next = records.filter({ $0.phase == .queued }).compactMap(\.retryAt).filter({ $0 > Date() })
            .min()
        {
            retryWake = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) } catch { return }
                self?.submit { await self?.drive() }
            }
        }
    }
    private func prepare(_ record: DownloadRecord) async {
        let key = DownloadTaskKey(id: record.id, attempt: UUID())
        guard
            await change(
                record.id,
                {
                    $0.phase = .preparing; $0.attempt = key.attempt; $0.message = nil
                })
        else { return }
        let cellular = allowsCellular
        preparations[record.id] = Task { [weak self] in
            guard let self else { return }
            do {
                var source = record.source
                let usenet = DownloadPolicy.supportsUsenet(source)
                let indexer = URLComponents(string: source.nzbUrl ?? "")?.host?.lowercased() == "nzbfinder.ws"
                let savedNZB = FileManager.default.fileExists(
                    atPath: UsenetDownloadTransfer.directory(record.id).appendingPathComponent("manifest.nzb")
                        .path)
                if record.httpRefreshSource == true
                    || (!indexer && !(usenet && savedNZB)
                        && (StreamPolicy.needsRefresh(source, fetchedAt: record.fetchedAt)
                            || (usenet && record.providerID != nil && source.servers == nil)))
                {
                    guard let resolveSource else { throw DownloadFailure.response }
                    source = try await resolveSource(record)
                }
                if DownloadPolicy.supportsUsenet(source) {
                    try await self.transferUsenet(record, key: key, source: source)
                    return
                }
                try await self.prepareHTTP(record, key: key, source: source, cellular: cellular)
            } catch is CancellationError {
                self.submit {
                    guard let phase = self.matching(key)?.phase else { return }
                    self.preparations[key.id] = nil
                    if phase == .pausing { await self.paused(key, data: nil); return }
                    guard phase == .preparing || phase == .downloading else { return }
                    _ = await self.change(key.id) {
                        $0.phase = .failed;
                        $0.message = "Source preparation was interrupted. Retry this download."
                    }
                    await self.drive()
                }
            } catch {
                let code = (error as? URLError)?.errorCode
                let message =
                    (error as? UsenetError)?.localizedDescription
                    ?? (error as? UsenetDownloadError)?.localizedDescription
                    ?? (error as? NZBFinderError)?.localizedDescription
                    ?? (error as? DownloadFailure)?.localizedDescription
                    ?? "The source is unavailable. Check your connection and retry."
                self.submit {
                    guard let phase = self.matching(key)?.phase else { return }
                    self.preparations[key.id] = nil
                    if phase == .pausing { await self.paused(key, data: nil); return }
                    guard phase == .preparing || phase == .downloading else { return }
                    if case .videoSelection(let files)? = error as? UsenetDownloadError {
                        _ = await self.change(key.id) {
                            $0.phase = .paused; $0.usenetFiles = files; $0.message = message
                        }
                        await self.drive(); return
                    }
                    if case .passwordRequired? = error as? UsenetDownloadError {
                        _ = await self.change(key.id) {
                            $0.phase = .paused; $0.usenetNeedsPassword = true; $0.message = message
                        }
                        await self.drive(); return
                    }
                    if let failure = error as? HTTPDownloadError {
                        switch failure {
                        case .status(let status, let after):
                            await self.failed(
                                key, code: 0, resumeData: nil, status: status, retryAfter: after)
                        default: await self.failed(key, code: NSURLErrorBadServerResponse, resumeData: nil)
                        }
                    } else if let code {
                        await self.failed(key, code: code, resumeData: nil)
                    } else {
                        _ = await self.change(key.id) {
                            $0.phase = .failed; $0.message = message
                        }; await self.drive()
                    }
                }
            }
        }
    }
    private func prepareHTTP(
        _ record: DownloadRecord, key: DownloadTaskKey, source: StreamSource, cellular: Bool
    ) async throws {
        let parallel = record.httpParallel == true
        let probe: DownloadProbe?
        do {
            probe =
                parallel || record.resumeData != nil
                ? try await DownloadProbe.inspect(source, allowsCellular: cellular) : nil
        } catch HTTPDownloadError.invalidRange where parallel {
            try await fallbackHTTP(record, key: key, source: source, cellular: cellular)
            return
        }
        try Task.checkCancellation()
        if parallel, let identity = probe?.rangeIdentity {
            try await schedule {
                guard self.matching(key)?.phase == .preparing, self.canTransfer, self.canExecuteInProcess
                else {
                    throw CancellationError()
                }
                guard
                    DownloadPolicy.hasSpace(
                        available: await self.storage.availableBytes(),
                        remaining: self.records.filter { $0.phase.isActive && $0.id != key.id }.map {
                            max(0, ($0.expectedBytes ?? 0) - self.progress(for: $0).bytes)
                        } + [identity.total, identity.total])
                else { throw DownloadFailure.storage }
                guard
                    await self.change(
                        key.id,
                        {
                            $0.phase = .downloading; $0.source = source; $0.fetchedAt = Date()
                            $0.fileName = key.id.uuidString + "." + (probe?.ext ?? "media")
                            $0.expectedBytes = identity.total; $0.etag = identity.etag;
                            $0.lastModified = probe?.modified
                            $0.httpWasResuming = false; $0.httpRefreshSource = false; $0.resumeData = nil
                        })
                else { throw DownloadFailure.unreadable }
                self.progress(for: record).reset(bytes: record.receivedBytes, total: identity.total)
            }.value
            do {
                let transfer = HTTPParallelDownload(
                    root: DownloadFiles.httpDirectory(key.id), source: try DownloadPolicy.url(for: source),
                    identity: identity, cellular: cellular
                ) { written, total in
                    await MainActor.run { self.receiveProgress(key, written: written, expected: total) }
                } finishing: { work in
                    await MainActor.run {
                        guard self.matching(key)?.phase == .downloading else { return }
                        self.progress(for: record).work = work
                        self.refreshBackground()
                    }
                }
                let receipt = try await transfer.run(destination: DownloadFiles.stagingURL(key))
                try Task.checkCancellation()
                try await schedule {
                    guard self.matching(key)?.phase == .downloading else { throw CancellationError() }
                    await self.finished(key, receipt: receipt)
                }.value
            } catch HTTPDownloadError.invalidRange {
                try await fallbackHTTP(record, key: key, source: source, cellular: cellular)
            } catch HTTPDownloadError.changed {
                try await fallbackHTTP(record, key: key, source: source, cellular: cellular)
            }
        } else if parallel {
            try await fallbackHTTP(record, key: key, source: source, cellular: cellular)
        } else {
            try await schedule {
                await self.begin(record, key: key, source: source, probe: probe, cellular: cellular)
            }.value
        }
    }
    private func fallbackHTTP(
        _ record: DownloadRecord, key: DownloadTaskKey, source: StreamSource, cellular: Bool
    ) async throws {
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: DownloadFiles.httpDirectory(key.id))
        try await schedule {
            guard let current = self.matching(key),
                current.phase == .preparing || current.phase == .downloading
            else { throw CancellationError() }
            guard
                await self.change(
                    key.id,
                    {
                        $0.phase = .preparing; $0.httpParallel = false; $0.resumeData = nil
                        $0.receivedBytes = 0; $0.httpWasResuming = false
                    }), let updated = self.matching(key)
            else { throw DownloadFailure.unreadable }
            await self.begin(updated, key: key, source: source, probe: nil, cellular: cellular)
        }.value
    }
    private func startHTTPWatchdog() {
        guard httpWatchdog == nil else { return }
        httpWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                self.submit { await self.checkHTTPStalls() }
            }
        }
    }
    private func checkHTTPStalls() async {
        guard canTransfer, canExecuteInProcess else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for (id, task) in tasks {
            guard task.state == .running, !httpWaiting.contains(id), let activity = httpActivity[id],
                now - activity.time >= 90,
                let record = records.first(where: { $0.id == id }), record.phase == .downloading,
                !DownloadPolicy.supportsUsenet(record.source)
            else { continue }
            let key = DownloadTaskKey(id: id, attempt: record.attempt)
            let resume = await task.cancelByProducingResumeData()
            if let receipt = await storage.stagedReceipt(key) {
                await finished(key, receipt: receipt)
            } else {
                await failed(key, code: NSURLErrorTimedOut, resumeData: resume)
            }
        }
    }
    private func transferUsenet(_ record: DownloadRecord, key: DownloadTaskKey, source: StreamSource)
        async throws
    {
        let output = try await UsenetDownloadTransfer.run(record: record, source: source, key: key) { total in
            try Task.checkCancellation()
            try await self.schedule {
                guard self.matching(key)?.phase == .preparing, self.canTransfer, self.canExecuteInProcess
                else {
                    throw CancellationError()
                }
                guard
                    DownloadPolicy.hasSpace(
                        available: await self.storage.availableBytes(),
                        remaining: [max(0, total - record.receivedBytes), total, total])
                else { throw DownloadFailure.storage }
                guard
                    await self.change(
                        key.id,
                        {
                            $0.phase = .downloading; $0.source = source; $0.fetchedAt = Date()
                            $0.fileName = key.id.uuidString + ".mkv"
                            $0.expectedBytes = total; $0.resumeData = nil; $0.message = nil;
                            $0.usenetFinishing = false
                        })
                else { throw DownloadFailure.unreadable }
                self.progress(for: record).reset(bytes: record.receivedBytes, total: total)
            }.value
        } progress: { written, total, connections in
            self.progress(for: record).connections = connections
            self.receiveProgress(key, written: written, expected: total)
        } stage: { work in
            try await self.schedule {
                guard self.matching(key)?.phase == .downloading else { throw CancellationError() }
                self.progress(for: record).connections = 0
                self.progress(for: record).work = work
                guard
                    await self.change(
                        key.id,
                        {
                            $0.message = work.stage.title; $0.usenetFinishing = true
                        })
                else {
                    throw DownloadFailure.unreadable
                }
            }.value
        } finishing: { work in
            guard self.matching(key)?.phase == .downloading else { return }
            self.progress(for: record).work = work
            self.refreshBackground()
        }
        try Task.checkCancellation()
        try await schedule {
            guard self.matching(key)?.phase == .downloading else { throw CancellationError() }
            let ext = (output.filename as NSString).pathExtension.lowercased()
            guard
                await self.change(
                    key.id,
                    {
                        $0.fileName = key.id.uuidString + "." + ext
                        $0.expectedBytes = output.receipt.total
                        $0.usenetNeedsPassword = nil; $0.usenetFiles = nil; $0.usenetFinishing = nil
                    })
            else { throw DownloadFailure.unreadable }
            await self.finished(key, receipt: output.receipt)
        }.value
    }

    private func begin(
        _ record: DownloadRecord, key: DownloadTaskKey, source: StreamSource, probe: DownloadProbe?,
        cellular: Bool
    ) async {
        guard matching(key)?.phase == .preparing, canExecuteInProcess, !backgroundStopping else { return }
        do {
            let url = try DownloadPolicy.url(for: source)
            let canResume =
                probe.map {
                    DownloadPolicy.canResume(
                        record, source: source, allowsCellular: cellular,
                        etag: $0.etag, modified: $0.modified, total: $0.total)
                } ?? false
            let total = probe?.total ?? source.behaviorHints?.videoSize.flatMap { $0 > 0 ? $0 : nil }
            let remaining =
                records.filter { $0.phase.isActive && $0.id != key.id }.map {
                    max(0, ($0.expectedBytes ?? 0) - progress(for: $0).bytes)
                } + [max(0, (total ?? 0) - (canResume ? record.receivedBytes : 0))]
            guard DownloadPolicy.hasSpace(available: await storage.availableBytes(), remaining: remaining)
            else { throw DownloadFailure.storage }
            let task: URLSessionDownloadTask
            if canResume, let data = record.resumeData {
                task = session.downloadTask(withResumeData: data)
            } else {
                var request = URLRequest(url: url); request.allowsCellularAccess = cellular
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                task = session.downloadTask(with: request)
            }
            task.taskDescription = key.description
            let ext =
                probe?.ext
                ?? DownloadPolicy.fileExtension(
                    url: url, filename: source.behaviorHints?.filename, mime: nil, prefix: Data())
            guard
                await change(
                    key.id,
                    {
                        $0.phase = .downloading; $0.source = source; $0.fetchedAt = Date()
                        $0.fileName = key.id.uuidString + "." + ext; $0.expectedBytes = total
                        $0.etag = probe?.etag; $0.lastModified = probe?.modified
                        $0.resumeAllowsCellular = cellular; $0.resumeData = nil
                        $0.httpWasResuming = canResume; $0.httpRefreshSource = false
                        $0.receivedBytes = canResume ? record.receivedBytes : 0
                        $0.message =
                            !canResume && record.receivedBytes > 0
                            ? "Restarting because the saved transfer cannot be resumed" : nil
                    })
            else { task.cancel(); preparations[key.id] = nil; return }
            progress(for: record).reset(bytes: canResume ? record.receivedBytes : 0, total: total)
            httpActivity[key.id] = (
                canResume ? record.receivedBytes : 0, ProcessInfo.processInfo.systemUptime
            )
            httpWaiting.remove(key.id)
            tasks[key.id] = task; preparations[key.id] = nil; task.resume()
        } catch {
            preparations[key.id] = nil
            _ = await change(key.id) {
                $0.phase = .failed;
                $0.message =
                    (error as? DownloadFailure)?.localizedDescription
                    ?? DownloadFailure.response.localizedDescription
            }
            await drive()
        }
    }
    private func matching(_ key: DownloadTaskKey) -> DownloadRecord? {
        records.first { $0.id == key.id && $0.attempt == key.attempt }
    }
    func receiveProgress(
        _ key: DownloadTaskKey, written: Int64, expected: Int64, etag: String? = nil, modified: String? = nil
    ) {
        submit {
            guard let record = self.matching(key), record.phase == .downloading else { return }
            self.progress(for: record).update(written, total: expected > 0 ? expected : record.expectedBytes)
            self.httpWaiting.remove(key.id)
            if written > (self.httpActivity[key.id]?.bytes ?? -1) {
                self.httpActivity[key.id] = (written, ProcessInfo.processInfo.systemUptime)
            }
            let checkpointDue = Date().timeIntervalSince(self.lastCheckpoint[key.id] ?? .distantPast) >= 5
            if record.message != nil || checkpointDue || (expected > 0 && record.expectedBytes != expected)
                || (record.etag == nil && etag != nil)
                || (record.lastModified == nil && modified != nil)
            {
                _ = await self.change(key.id) {
                    $0.message = nil; if expected > 0 { $0.expectedBytes = expected }
                    if checkpointDue { $0.receivedBytes = written }
                    if written >= 1024 * 1024, written > record.receivedBytes { $0.httpAuthRetries = 0 }
                    if let etag { $0.etag = etag }; if let modified { $0.lastModified = modified }
                }
            }
            if checkpointDue { self.lastCheckpoint[key.id] = Date() }
            self.refreshBackground()
            if checkpointDue, await self.storage.availableBytes() < DownloadPolicy.storageReserve {
                await self.pause(key.id);
                _ = await self.change(key.id) { $0.message = DownloadFailure.storage.localizedDescription }
            }
        }
    }
    func receiveCompletion(_ key: DownloadTaskKey, receipt: DownloadReceipt) {
        submit { await self.finished(key, receipt: receipt) }
    }
    private func finished(_ key: DownloadTaskKey, receipt: DownloadReceipt) async {
        do {
            library = try await storage.complete(library, key: key, receipt: receipt)
            if matching(key)?.phase == .completed {
                tasks[key.id] = nil; preparations[key.id] = nil
                httpActivity[key.id] = nil; httpWaiting.remove(key.id)
                try? FileManager.default.removeItem(at: DownloadFiles.httpDirectory(key.id))
                if let record = matching(key), DownloadPolicy.supportsUsenet(record.source) {
                    try? FileManager.default.removeItem(at: UsenetDownloadTransfer.directory(key.id))
                    try? SecureStorage.delete(.archivePassword(key.id))
                    notifyDownload(record)
                }
            }
            disk = await storage.diskState()
        } catch {
            tasks[key.id] = nil
            // A saved final file is preserved and completed by the next reconciliation.
            if let record = matching(key), await storage.file(record) != nil {
                self.error =
                    "The file is saved, but its record could not be updated. Free storage and reopen Downloads."
            } else if matching(key) != nil {
                _ = await change(key.id) {
                    $0.phase = .failed;
                    $0.message =
                        (error as? DownloadFailure)?.localizedDescription
                        ?? "The downloaded file could not be saved. Free storage and retry."
                }
            }
        }
        await drive()
    }
    func receiveFailure(_ key: DownloadTaskKey, code: Int, resumeData: Data?) {
        submit { await self.failed(key, code: code, resumeData: resumeData) }
    }
    private func failed(
        _ key: DownloadTaskKey, code: Int, resumeData: Data?, status: Int? = nil, retryAfter: String? = nil
    ) async {
        guard let record = matching(key), record.phase != .completed else { return }
        if record.phase == .pausing {
            if let resumeData { _ = await change(key.id) { $0.resumeData = resumeData } }
            return
        }
        guard record.phase == .downloading || record.phase == .preparing else { return }
        tasks[key.id] = nil; httpActivity[key.id] = nil; httpWaiting.remove(key.id)
        let http = !DownloadPolicy.supportsUsenet(record.source)
        let auth =
            http && [401, 403].contains(status ?? 0) && resolveSource != nil
            && (record.httpAuthRetries ?? 0) == 0 && record.retryCount < HTTPDownloadPolicy.maximumRetries
        let restart =
            http
            && HTTPDownloadPolicy.shouldRestartResume(
                code: code, status: status,
                wasResuming: record.httpWasResuming == true || record.resumeData != nil,
                recoveries: record.httpResumeRecoveries ?? 0)
        let delay = HTTPDownloadPolicy.retryDelay(
            status: status, code: code, retryAfter: retryAfter,
            attempt: record.retryCount + 1, jitter: Double.random(in: 0...1))
        _ = await change(key.id) {
            $0.receivedBytes = progress(for: record).bytes
            $0.resumeData =
                restart ? nil : (resumeData ?? (record.phase == .preparing ? record.resumeData : nil))
            $0.retryCount += 1
            let automatic = auth || restart || delay != nil
            $0.phase = automatic ? .queued : .failed
            $0.retryAt = automatic ? Date().addingTimeInterval(auth || restart ? 0 : (delay ?? 0)) : nil
            if auth {
                $0.httpAuthRetries = (record.httpAuthRetries ?? 0) + 1; $0.httpRefreshSource = true
                $0.fetchedAt = .distantPast; $0.message = "Refreshing expired download link…"
            } else if restart {
                $0.httpResumeRecoveries = (record.httpResumeRecoveries ?? 0) + 1
                $0.httpWasResuming = false; $0.receivedBytes = 0
                $0.message = "Restarting because the server could not resume this file"
            } else if delay != nil {
                $0.message = "Waiting to retry"
            } else if status == 401 || status == 403 {
                $0.fetchedAt = .distantPast
                $0.message = "The download link expired. Retry or choose another source."
            } else if let status {
                $0.message = "The download server returned HTTP \(status). Retry or choose another source."
            } else {
                $0.message = "Download interrupted. Check your connection, storage and source, then retry."
            }
        }
        await drive()
    }
    func receiveHTTPFailure(
        _ key: DownloadTaskKey, status: Int?, code: Int, retryAfter: String?, resumeData: Data? = nil
    ) {
        submit {
            await self.failed(key, code: code, resumeData: resumeData, status: status, retryAfter: retryAfter)
        }
    }
    func receiveResumed(_ key: DownloadTaskKey, offset: Int64, total: Int64) {
        submit {
            guard let record = self.matching(key), record.phase == .downloading else { return }
            self.httpWaiting.remove(key.id)
            self.httpActivity[key.id] = (offset, ProcessInfo.processInfo.systemUptime)
            self.progress(for: record).reset(bytes: offset, total: total > 0 ? total : record.expectedBytes)
            _ = await self.change(key.id) {
                $0.receivedBytes = offset; $0.httpWasResuming = offset > 0
                if total > 0 { $0.expectedBytes = total }
                if offset == 0, record.receivedBytes > 0 { $0.message = "The server restarted this download" }
            }
        }
    }
    func receiveWaiting(_ key: DownloadTaskKey) {
        submit {
            guard self.matching(key)?.phase == .downloading else { return }
            self.httpWaiting.insert(key.id)
            _ = await self.change(key.id) {
                $0.message =
                    self.cellularNetwork && !self.allowsCellular
                    ? "Waiting for Wi-Fi" : "Waiting for connection"
            }
        }
    }
    func receiveRejection(_ key: DownloadTaskKey, status: Int) {
        submit {
            guard self.matching(key)?.phase.isActive == true else { return }
            if status != 200 && status != 206 {
                await self.failed(key, code: 0, resumeData: nil, status: status); return
            }
            self.tasks[key.id] = nil
            _ = await self.change(key.id) {
                $0.phase = .failed
                if status == 401 || status == 403 { $0.fetchedAt = .distantPast }
                $0.message =
                    status == 200 || status == 206
                    ? DownloadFailure.unsupported.localizedDescription
                    : DownloadFailure.response.localizedDescription
            }
            await self.drive()
        }
    }
    func finishBackgroundEvents() {
        submit {
            let completion = self.backgroundCompletion; self.backgroundCompletion = nil; completion?()
        }
    }
    func fileURL(_ record: DownloadRecord) -> URL? {
        guard let name = record.fileName, DownloadPolicy.safeName(name), let size = disk.media[name],
            size > 0,
            record.phase != .completed || size == record.receivedBytes
        else { return nil }
        return DownloadFiles.media.appendingPathComponent(name)
    }
    func validatedURL(_ record: DownloadRecord) async -> URL? { await storage.file(record) }
    func candidates(media: MediaItem, video: VideoSelection) -> [DownloadRecord] {
        records.filter {
            var candidate = $0
            if candidate.phase == .failed, candidate.message == DownloadFailure.missing.localizedDescription {
                candidate.phase = .completed
            }
            return DownloadPlayback.matches(
                candidate, media: media, videoID: video.id, episode: video.episode)
        }
    }
    func protect(_ ids: Set<UUID>) { fileLeases.acquire(ids) }
    func unprotect(_ ids: Set<UUID>) { fileLeases.release(ids) }
    private func remove(_ ids: Set<UUID>) async {
        guard protectedIDs.isDisjoint(with: ids) else {
            error = "Close playback or the share sheet before removing these downloads."; return
        }
        let selected = records.filter { ids.contains($0.id) }
        // Acquire a deletion lease before awaiting storage so a new presenter cannot open these files.
        removing.formUnion(ids)
        defer { removing.subtract(ids) }
        do {
            library = try await storage.remove(ids, from: library)
            for record in selected {
                tasks.removeValue(forKey: record.id)?.cancel();
                let preparation = preparations.removeValue(forKey: record.id)
                preparation?.cancel()
                Task {
                    await preparation?.value
                    try? FileManager.default.removeItem(at: UsenetDownloadTransfer.directory(record.id))
                    try? SecureStorage.delete(.archivePassword(record.id))
                    try? FileManager.default.removeItem(at: DownloadFiles.httpDirectory(record.id))
                }
                httpActivity[record.id] = nil; httpWaiting.remove(record.id)
                progressValues[record.id] = nil; lastCheckpoint[record.id] = nil
                policyPauses.remove(record.id)
            }
            disk = await storage.diskState(); await drive()
        } catch { self.error = "These downloads could not be removed. Their files have been preserved." }
    }
    func selectUsenetFile(_ id: UUID, name: String) {
        submit {
            guard let record = self.records.first(where: { $0.id == id }),
                record.usenetFiles?.contains(name) == true
            else { return }
            guard
                await self.change(
                    id,
                    {
                        $0.usenetSelectedFile = name; $0.usenetFiles = nil
                    })
            else { return }
            await self.resume(id)
        }
    }
    func setArchivePassword(_ id: UUID, password: String) {
        submit {
            guard self.records.contains(where: { $0.id == id && $0.usenetNeedsPassword == true }) else {
                return
            }
            do { try SecureStorage.save(password, for: .archivePassword(id)) } catch {
                self.error = error.localizedDescription; return
            }
            guard await self.change(id, { $0.usenetNeedsPassword = nil }) else { return }
            await self.resume(id)
        }
    }
    func pauseAll() {
        submit {
            for record in self.records where record.phase == .queued || record.phase.isActive {
                await self.pause(record.id)
            }
        }
    }
    func resumeAll() {
        submit {
            for record in self.records
            where record.phase == .paused && record.usenetNeedsPassword != true && record.usenetFiles == nil {
                await self.resume(record.id)
            }
        }
    }
    func reorder(_ ids: [UUID]) {
        submit {
            var proposed = self.library
            let order = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
            proposed.records.sort { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
            _ = await self.commit(proposed)
        }
    }
    func reserveUsenetPlayback(_ token: UUID) async throws {
        let running = try await schedule {
            self.usenetPlaybackReservation = token
            let running = self.preparations.filter { id, _ in
                self.records.contains { $0.id == id && DownloadPolicy.supportsUsenet($0.source) }
            }.map(\.value)
            await self.drive()
            return running
        }.value
        for task in running { await task.value }
        try Task.checkCancellation()
    }
    func releaseUsenetPlayback(_ token: UUID) {
        submit {
            guard self.usenetPlaybackReservation == token else { return }
            self.usenetPlaybackReservation = nil
            await self.drive()
        }
    }
    private func stopBackgroundDownloads() async {
        let workers: [Task<Void, Never>] =
            (try? await schedule {
                self.backgroundStopping = true; self.policyPauses.removeAll()
                self.retryWake?.cancel(); self.retryWake = nil
                let selected = self.records.filter { $0.phase == .queued || $0.phase.isActive }
                let selectedIDs = Set(selected.map(\.id))
                var proposed = self.library
                for index in proposed.records.indices
                where selectedIDs.contains(proposed.records[index].id) {
                    proposed.records[index].phase = .paused
                    proposed.records[index].receivedBytes = self.progress(for: proposed.records[index]).bytes
                    proposed.records[index].message = "Paused. Resume to continue."
                }
                if !(await self.commit(proposed)) {
                    // Stop must still take effect if storage is full. Recovery pauses interrupted jobs.
                    self.library = proposed
                }
                var workers: [Task<Void, Never>] = []
                for record in selected {
                    if let worker = self.preparations.removeValue(forKey: record.id) {
                        workers.append(worker); worker.cancel()
                    }
                    if let task = self.tasks.removeValue(forKey: record.id) {
                        let data = await task.cancelByProducingResumeData()
                        let key = DownloadTaskKey(id: record.id, attempt: record.attempt)
                        if let receipt = await self.storage.stagedReceipt(key) {
                            await self.finished(key, receipt: receipt)
                        } else if let data {
                            _ = await self.change(record.id) { $0.resumeData = data }
                        }
                    }
                    self.httpActivity[record.id] = nil; self.httpWaiting.remove(record.id)
                }
                return workers
            }.value) ?? []
        // Workers may be waiting on the transaction queue themselves. Never join them inside it.
        for worker in workers { await worker.value }
        _ = try? await schedule {
            self.backgroundStopping = false
            self.endUsenetBackgroundTask()
            await self.drive()
        }.value
    }
    func enterBackground() {
        endUsenetBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Vesper download checkpoint") {
            [weak self] in
            Task { @MainActor in self?.endUsenetBackgroundTask() }
        }
        submit {
            self.appBackground = true; await self.drive()
        }
    }
    func enterForeground() {
        submit {
            self.appBackground = false; await self.drive()
        }
    }
    func updateUsenetIdleTimer() {
        let active = records.contains { $0.phase.isActive && DownloadPolicy.supportsUsenet($0.source) }
        if !records.contains(where: { $0.phase.isActive && preparations[$0.id] != nil })
            || background.isGranted
        {
            endUsenetBackgroundTask()
        }
        ScreenAwake.set(
            ScreenAwake.downloads,
            active: active && !appBackground && UsenetDownloadOptions.shared.keepAwake)
    }

    private func endUsenetBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    private func notifyDownload(_ record: DownloadRecord) {
        guard UsenetDownloadOptions.shared.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download complete"; content.body = record.media.name; content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil))
    }
    @ObservationIgnored private var removing = Set<UUID>()
    func acquire(_ id: UUID) -> Bool {
        guard !removing.contains(id), records.contains(where: { $0.id == id && $0.phase == .completed })
        else { return false }
        protect([id]); return true
    }
    func export(_ record: DownloadRecord) async throws -> URL { try await storage.export(record) }
    func finishExport(_ url: URL) { submit { await self.storage.finishExport(url) } }
    private func resumeArtwork() {
        guard recovered, canTransfer else { return }
        for record in records {
            for raw in record.artworkURLs {
                guard localArtwork(raw, record: record) == nil, artworkTasks[raw] == nil,
                    let url = try? AddonURL.http(raw)
                else { continue }
                artworkTasks[raw] = Task { [weak self] in
                    do {
                        let data = try await ArtworkDataClient.shared.data(for: url, priority: .prefetch)
                        try Task.checkCancellation()
                        self?.submit { await self?.saveArtwork(data, raw: raw) }
                    } catch { self?.submit { self?.artworkTasks[raw] = nil } }
                }
            }
        }
    }
    private func linkSharedArtwork() async {
        var proposed = library
        var changed = false
        for index in proposed.records.indices {
            let record = proposed.records[index]
            for raw in record.artworkURLs {
                if let url = localArtwork(raw, record: record), record.artwork[raw] != url.lastPathComponent {
                    proposed.records[index].artwork[raw] = url.lastPathComponent; changed = true
                }
            }
        }
        if changed { _ = await commit(proposed) }
    }
    private func saveArtwork(_ data: Data, raw: String) async {
        defer { artworkTasks[raw] = nil }
        let ids = Set(records.filter { $0.artworkURLs.contains(raw) }.map(\.id))
        guard !ids.isEmpty else { return }
        let name = UUID().uuidString + ".image"
        do {
            try await storage.storeArtwork(data, name: name)
            var proposed = library
            for index in proposed.records.indices where ids.contains(proposed.records[index].id) {
                proposed.records[index].artwork[raw] = name
            }
            _ = await commit(proposed); disk = await storage.diskState()
        } catch { /* Missing artwork is retried on foreground or connectivity changes. */  }
    }
    func rememberDetailArtwork(_ artwork: DetailArtwork, for media: MediaItem) {
        guard !artwork.urls.isEmpty else { return }
        if detailArtworkSnapshots.count > 1200 { detailArtworkSnapshots.removeAll() }
        for alias in MediaIdentity.aliases(media) { detailArtworkSnapshots[alias] = artwork }
        submit {
            var proposed = self.library
            var changed = false
            for index in proposed.records.indices where proposed.records[index].media.isSameTitle(as: media) {
                if proposed.records[index].detailArtwork != artwork {
                    proposed.records[index].detailArtwork = artwork; changed = true
                }
            }
            if changed, await self.commit(proposed) { self.resumeArtwork() }
        }
    }
    func offlineDetailArtwork(for media: MediaItem) -> DetailArtwork {
        guard let record = completed.first(where: { $0.media.isSameTitle(as: media) }),
            let artwork = record.detailArtwork
        else { return DetailArtwork() }
        return artwork.mappingURLs { self.localArtwork($0, record: record)?.absoluteString }
    }
    func offlineMedia(_ record: DownloadRecord) -> MediaItem {
        var media = record.media
        media.poster = localArtwork(record.media.poster, record: record)?.absoluteString
        media.background = localArtwork(record.media.background, record: record)?.absoluteString
        return media
    }
    func localArtwork(_ raw: String?, record: DownloadRecord) -> URL? {
        guard let raw else { return nil }
        if let name = record.artwork[raw], disk.artwork.contains(name) {
            return DownloadFiles.artwork.appendingPathComponent(name)
        }
        guard let name = records.lazy.compactMap({ $0.artwork[raw] }).first(where: disk.artwork.contains)
        else { return nil }
        return DownloadFiles.artwork.appendingPathComponent(name)
    }
    func offlineEpisode(_ record: DownloadRecord) -> Episode? {
        record.episode.map {
            $0.offlineSnapshot(thumbnail: localArtwork($0.thumbnail, record: record)?.absoluteString)
        }
    }
}
