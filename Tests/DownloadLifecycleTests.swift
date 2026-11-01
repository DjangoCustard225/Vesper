import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Observation
import VesperCore

// ACTUAL_PROGRESS

@MainActor enum DownloadFiles {
    static var root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static var media: URL { root.appendingPathComponent("Media") }
    static var artwork: URL { root.appendingPathComponent("Artwork") }
    static func httpDirectory(_ id: UUID) -> URL { root.appendingPathComponent("HTTPJobs/" + id.uuidString) }
}
@MainActor enum UsenetDownloadTransfer {
    static func directory(_ id: UUID) -> URL {
        DownloadFiles.root.appendingPathComponent("UsenetJobs/" + id.uuidString)
    }
}
enum SecureStorage {
    struct Key { static func archivePassword(_ id: UUID) -> Self { Self() } }
    static func delete(_ key: Key) throws {}
}
@MainActor final class TaskDouble {
    var taskDescription: String?
    var resumptions = 0
    func resume() { resumptions += 1 }
    var cancellations = 0
    func cancel() { cancellations += 1 }
    func cancelByProducingResumeData() async -> Data? { cancellations += 1; return Data([1, 2, 3]) }
}
struct DownloadProbe: Sendable {
    let total: Int64?
    let ext: String
    let etag: String?
    let modified: String?
}
@MainActor final class SessionDouble {
    var created: [TaskDouble] = []
    func downloadTask(with: URLRequest) -> TaskDouble {
        let task = TaskDouble(); created.append(task); return task
    }
    func downloadTask(withResumeData: Data) -> TaskDouble {
        let task = TaskDouble(); created.append(task); return task
    }
}
@MainActor final class DownloadProbeController {
    let session = SessionDouble()
    var library = DownloadLibrary()
    var disk = DownloadDiskState()
    var error: String?
    var writable = true
    let storage: DownloadStorage
    var tasks: [UUID: TaskDouble] = [:]
    var preparations: [UUID: Task<Void, Never>] = [:]
    var lastCheckpoint: [UUID: Date] = [:]
    var progressValues: [UUID: DownloadProgress] = [:]
    var fileLeases = DownloadFileLeases()
    var policyPauses = Set<UUID>()
    var removing = Set<UUID>()
    var operationTail: Task<Void, Never>?
    var backgroundCompletion: (() -> Void)?
    var httpActivity: [UUID: (bytes: Int64, time: TimeInterval)] = [:]
    var httpWaiting = Set<UUID>()
    var resolveSource: (@MainActor (DownloadRecord) async throws -> StreamSource)?
    var recovered = true
    var canTransfer = true
    var usenetPlaybackReservation: UUID?
    var prepared: [UUID] = []
    func updateUsenetIdleTimer() {}
    func prepare(_ record: DownloadRecord) async {
        prepared.append(record.id)
        _ = await change(record.id) { $0.phase = .preparing }
    }
    var retryWake: Task<Void, Never>?
    func endUsenetBackgroundTask() {}
    var backgroundStopping = false
    var canExecuteInProcess = true
    func refreshBackground(force: Bool = false) {}
    func requestBackground() {}
    var driveCalls = 0
    var records: [DownloadRecord] { library.records }
    var completed: [DownloadRecord] { records.filter { $0.phase == .completed } }
    var protectedIDs: Set<UUID> { fileLeases.ids }
    init(failing: Bool = false) {
        storage = DownloadStorage(
            root: DownloadFiles.root,
            repository: failing
                ? DownloadRepository(
                    url: DownloadFiles.root.appendingPathComponent("index.json"),
                    write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }) : nil)
    }
    func notifyDownload(_ record: DownloadRecord) {}
    func drive() async { driveCalls += 1 }
    func drain() async { await operationTail?.value }
    // ACTUAL_METHODS
}
@main @MainActor struct Regression {
    static func main() async throws {
        let root = DownloadFiles.root
        let storage = DownloadStorage(root: root)
        _ = try await storage.load()
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); passed += 1
        }
        func record() throws -> DownloadRecord {
            let source = try JSONDecoder().decode(
                StreamSource.self, from: Data(#"{"url":"https://files.example/movie.mkv"}"#.utf8))
            var value = DownloadRecord(
                media: MediaItem(id: "tt1", type: "movie", name: "Movie", poster: nil), videoID: "tt1",
                subtitle: nil,
                episode: nil, source: source, providerID: nil, fetchedAt: Date())
            value.phase = .downloading; value.expectedBytes = 8; value.fileName = value.id.uuidString + ".mkv"
            return value
        }
        func receipt(total: Int64? = 8) throws -> DownloadReceipt {
            let url = root.appendingPathComponent("Incoming").appendingPathComponent(UUID().uuidString)
            try Data([0x1a, 0x45, 0xdf, 0xa3, 0, 1, 2, 3]).write(to: url)
            return DownloadReceipt(location: url, status: 200, mime: "video/x-matroska", total: total)
        }
        do {
            let model = DownloadProbeController(), value = try record()
            model.library.records = [value]; model.tasks[value.id] = TaskDouble()
            await model.finished(
                DownloadTaskKey(id: value.id, attempt: value.attempt), receipt: try receipt())
            check(
                model.records[0].phase == .completed && model.fileURL(model.records[0]) != nil,
                "Completion saves the file and index before publishing")
            check(model.tasks.isEmpty, "Completion frees its task slot")
            model.protect([value.id]); model.protect([value.id]); model.unprotect([value.id])
            await model.remove([value.id])
            check(model.records.count == 1, "Playback still protects a file after export ends")
            model.unprotect([value.id]); await model.remove([value.id])
            check(
                model.records.isEmpty && model.fileURL(value) == nil,
                "Only an unleased download can be removed")
        }
        do {
            let model = DownloadProbeController(), value = try record()
            model.library.records = [value]
            await model.finished(DownloadTaskKey(id: value.id, attempt: UUID()), receipt: try receipt())
            check(model.records[0].phase == .downloading, "Old attempts cannot complete new transfers")
            await model.finished(
                DownloadTaskKey(id: value.id, attempt: value.attempt), receipt: try receipt(total: 10))
            check(
                model.records[0].phase == .failed && model.fileURL(value) == nil,
                "Incomplete files cannot become playable")
        }
        do {
            let model = DownloadProbeController(); var value = try record(); value.phase = .pausing
            model.library.records = [value]; model.tasks[value.id] = TaskDouble()
            let key = DownloadTaskKey(id: value.id, attempt: value.attempt)
            await model.failed(key, code: NSURLErrorCancelled, resumeData: nil)
            check(
                model.records[0].phase == .pausing && model.driveCalls == 0,
                "Cancellation waits for its resume-data callback")
            await model.paused(key, data: Data([9]))
            check(
                model.records[0].phase == .paused && model.records[0].resumeData == Data([9]),
                "Pause persists native resume data")
            await model.paused(key, data: nil)
            check(
                model.records[0].resumeData == Data([9]), "Duplicate callbacks cannot erase saved resume data"
            )
            await model.resume(value.id)
            check(
                model.records[0].phase == .queued && model.records.count == 1,
                "Resume reuses the existing job")
        }
        do {
            let model = DownloadProbeController(); var value = try record(); value.phase = .queued
            model.library.records = [value]; model.canExecuteInProcess = false
            await model.runDrive()
            check(model.prepared.isEmpty, "Without a grant no background source preparation starts")
            model.canExecuteInProcess = true
            await model.runDrive()
            check(model.prepared == [value.id], "A grant lets the existing queue advance")
        }
        do {
            let model = DownloadProbeController(), value = try record()
            model.library.records = [value]; let task = TaskDouble(); model.tasks[value.id] = task
            model.canExecuteInProcess = false
            await model.runDrive()
            check(
                model.records[0].phase == .downloading && task.cancellations == 0,
                "Standard HTTP remains independent of continued-processing permission")
        }
        do {
            let model = DownloadProbeController(), first = try record()
            var second = try record(); second.phase = .queued
            model.library.records = [first, second]; model.tasks[first.id] = TaskDouble()
            model.policyPauses = [first.id, second.id]
            var joinedQueue = false
            model.preparations[second.id] = Task {
                do { try await Task.sleep(for: .seconds(30)) } catch {}
                _ = try? await model.schedule { joinedQueue = true }.value
            }
            await model.stopBackgroundDownloads()
            check(
                model.records.allSatisfy { $0.phase == .paused },
                "System Stop atomically pauses active and queued downloads")
            check(model.records[0].resumeData == Data([1, 2, 3]), "System Stop preserves native resume data")
            check(
                joinedQueue && model.preparations.isEmpty,
                "Workers checkpoint outside the transaction queue without deadlock")
            check(
                model.policyPauses.isEmpty && !model.backgroundStopping,
                "System Stop cannot automatically restart paused work")
        }
        do {
            let model = DownloadProbeController(failing: true), value = try record()
            model.library.records = [value]; model.tasks[value.id] = TaskDouble()
            await model.stopBackgroundDownloads()
            check(
                model.records[0].phase == .paused && model.tasks.isEmpty && model.error != nil,
                "System Stop still stops transfers if the index cannot be saved")
        }
        do {
            let model = DownloadProbeController(); var value = try record(); value.phase = .paused
            model.library.records = [value]
            await model.finished(
                DownloadTaskKey(id: value.id, attempt: value.attempt), receipt: try receipt())
            check(model.records[0].phase == .completed, "Verified completion wins a pause race")
        }
        do {
            let model = DownloadProbeController(), value = try record(); model.library.records = [value]
            let key = DownloadTaskKey(id: value.id, attempt: value.attempt)
            await model.failed(key, code: NSURLErrorTimedOut, resumeData: Data([1]))
            check(
                model.records[0].phase == .queued && model.records[0].retryAt != nil,
                "Transient errors use bounded delayed retries")
            model.library.records[0].phase = .downloading;
            model.library.records[0].retryCount = HTTPDownloadPolicy.maximumRetries
            await model.failed(key, code: NSURLErrorTimedOut, resumeData: nil)
            check(model.records[0].phase == .failed, "Retries stop after the budget is exhausted")
        }
        do {
            let model = DownloadProbeController(); var value = try record()
            value.httpWasResuming = true
            model.library.records = [value]
            let key = DownloadTaskKey(id: value.id, attempt: value.attempt)
            await model.failed(key, code: NSURLErrorCannotOpenFile, resumeData: Data([1]))
            check(
                model.records[0].phase == .queued && model.records[0].resumeData == nil,
                "Broken resume data restarts without reusing it")
            model.library.records[0].phase = .downloading
            model.library.records[0].httpWasResuming = true
            await model.failed(key, code: NSURLErrorCannotOpenFile, resumeData: nil)
            check(model.records[0].phase == .failed, "Resume recovery cannot loop")
        }
        do {
            let model = DownloadProbeController(), value = try record()
            model.library.records = [value]; model.resolveSource = { $0.source }
            let key = DownloadTaskKey(id: value.id, attempt: value.attempt)
            await model.failed(key, code: 0, resumeData: nil, status: 403)
            check(
                model.records[0].phase == .queued && model.records[0].httpRefreshSource == true,
                "Expired links request a fresh provider URL")
            model.library.records[0].phase = .downloading
            await model.failed(key, code: 0, resumeData: nil, status: 403)
            check(model.records[0].phase == .failed, "Repeated authorization failures stop automatically")
        }
        do {
            let model = DownloadProbeController(), value = try record(); model.library.records = [value]
            model.receiveRejection(DownloadTaskKey(id: value.id, attempt: value.attempt), status: 403)
            await model.drain()
            check(
                model.records[0].fetchedAt == .distantPast && model.records[0].phase == .failed,
                "Expired links require an exact-source refresh")
        }
        do {
            let model = DownloadProbeController(), value = try record(); model.library.records = [value]
            model.submit { _ = await model.change(value.id) { $0.phase = .paused } }
            model.submit { _ = await model.change(value.id) { $0.message = "second" } }
            var acknowledged = false
            model.backgroundCompletion = { acknowledged = true }
            model.finishBackgroundEvents()
            await model.drain()
            let persisted = try await model.storage.load()
            check(
                acknowledged && persisted.records[0].phase == .paused
                    && persisted.records[0].message == "second",
                "Commands cannot lose updates across storage awaits and background acknowledgement follows durable writes"
            )
        }
        do {
            let model = DownloadProbeController(failing: true), value = try record();
            model.library.records = [value]
            let task = TaskDouble(); model.tasks[value.id] = task
            await model.finished(
                DownloadTaskKey(id: value.id, attempt: value.attempt), receipt: try receipt())
            check(
                model.records[0].phase == .downloading && model.error != nil,
                "Failed completion writes preserve the published state")
            let saved = await model.storage.file(value)
            check(saved != nil, "Verified files survive failed completion writes")
            await model.remove([value.id])
            let restored = await model.storage.file(value)
            check(
                model.records.count == 1 && restored != nil && task.cancellations == 0,
                "Failed removal rolls back the file without cancelling its transfer")
        }
        do {
            let model = DownloadProbeController(failing: true)
            var value = try record(); value.phase = .preparing
            model.library.records = [value]; model.preparations[value.id] = Task {}
            await model.begin(
                value, key: DownloadTaskKey(id: value.id, attempt: value.attempt), source: value.source,
                probe: nil, cellular: false)
            check(
                model.preparations[value.id] == nil && model.tasks[value.id] == nil,
                "A failed transfer-start write releases preparation ownership for foreground recovery")
            check(
                model.session.created.count == 1 && model.session.created[0].resumptions == 0
                    && model.session.created[0].cancellations == 1, "An uncommitted native task never starts")
        }
        do {
            let model = DownloadProbeController(); var one = try record(), two = try record()
            one.media.poster = "https://images.example/poster"; two.media.poster = one.media.poster
            one.artwork = [one.media.poster!: "missing.image"]
            two.artwork = [two.media.poster!: "shared.image"]
            try await model.storage.storeArtwork(Data([1, 2, 3]), name: "shared.image")
            model.library.records = [one, two]; model.disk = await model.storage.diskState()
            await model.linkSharedArtwork()
            check(
                model.records.allSatisfy { $0.artwork[one.media.poster!] == "shared.image" },
                "A missing artwork reference adopts the shared valid cache entry")
            let offline = model.offlineMedia(model.records[0])
            check(
                offline.poster?.hasPrefix("file:") == true && offline.background == nil,
                "Offline presentation never falls back to remote artwork")
        }
        print("Passed \(passed) download lifecycle regression checks.")
    }
}
