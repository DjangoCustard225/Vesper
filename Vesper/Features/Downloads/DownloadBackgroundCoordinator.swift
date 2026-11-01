import Foundation
import Observation
import VesperCore

@MainActor protocol DownloadBackgroundTask: AnyObject {
    var progress: Progress { get }
    var expirationHandler: (@Sendable () -> Void)? { get set }
    func update(title: String, subtitle: String)
    func complete(success: Bool)
}

@MainActor protocol DownloadBackgroundScheduling: AnyObject {
    func submit(identifier: String, launch: @escaping @MainActor (any DownloadBackgroundTask) -> Void)
        async throws
    func cancel(identifier: String)
}

struct DownloadBackgroundItem {
    let id: UUID
    let title: String
    let phase: DownloadPhase
    let bytes: Int64
    let total: Int64?
    let work: DownloadWorkProgress?
    let message: String?
    var speed: Double = 0
    var runnable: Bool { phase.isActive || phase == .queued }
}

/// Owns one system activity for a user-started queue, independently of scene changes.
@MainActor @Observable final class DownloadBackgroundCoordinator {
    private(set) var isGranted = false
    private(set) var status: String?
    @ObservationIgnored var onPermissionChange: (() -> Void)?
    @ObservationIgnored var onStop: (() async -> Void)?
    @ObservationIgnored private let scheduler: any DownloadBackgroundScheduling
    @ObservationIgnored private var identifier: String?
    @ObservationIgnored private var systemTask: (any DownloadBackgroundTask)?
    @ObservationIgnored private var submission: Task<Void, Never>?
    @ObservationIgnored private var members = Set<UUID>()
    @ObservationIgnored private var finishingUnits: [UUID: Int64] = [:]
    @ObservationIgnored private var currentID: UUID?
    @ObservationIgnored private var items: [DownloadBackgroundItem] = []
    @ObservationIgnored private var lastUpdate: TimeInterval = 0

    init(scheduler: any DownloadBackgroundScheduling) { self.scheduler = scheduler }

    func request(items: [DownloadBackgroundItem]) {
        guard items.contains(where: \.runnable) else { return }
        if identifier != nil {
            members.formUnion(items.filter(\.runnable).map(\.id))
            update(items: items, force: true)
            return
        }
        let identifier = "app.vesper.downloads.continued." + UUID().uuidString
        self.identifier = identifier; self.items = items
        members = Set(items.filter(\.runnable).map(\.id)); finishingUnits = [:]; currentID = nil
        status = "Waiting for background download permission"
        submission = Task { [weak self] in
            guard let self, self.identifier == identifier, !Task.isCancelled else { return }
            do {
                try await self.scheduler.submit(identifier: identifier) { [weak self] task in
                    guard let self, self.identifier == identifier else {
                        task.complete(success: false); return
                    }
                    if let current = self.systemTask {
                        if current !== task { task.complete(success: false) }
                        return
                    }
                    self.systemTask = task; self.isGranted = true; self.status = nil
                    task.expirationHandler = { [weak self] in
                        Task { @MainActor in self?.expired(identifier) }
                    }
                    self.update(items: self.items, force: true)
                    self.onPermissionChange?()
                }
            } catch {
                guard self.identifier == identifier else { return }
                self.finish(success: false)
                self.status =
                    "Background processing unavailable. HTTP downloads can still continue in the background."
                self.onPermissionChange?()
            }
        }
    }

    func update(items: [DownloadBackgroundItem], force: Bool = false) {
        self.items = items
        guard identifier != nil else { return }
        let owned = items.filter { members.contains($0.id) }
        guard owned.contains(where: \.runnable) else {
            finish(success: !owned.isEmpty && owned.allSatisfy { $0.phase == .completed })
            return
        }
        guard let task = systemTask else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastUpdate >= 1 else { return }
        lastUpdate = now
        let active = owned.filter { $0.phase == .downloading }
        let current =
            active.first { $0.id == currentID } ?? active.first
            ?? owned.first(where: \.runnable)
        currentID = current?.id
        let stage =
            current?.work?.stage.title ?? current?.message
            ?? (current?.phase == .preparing ? "Preparing…" : "Downloading")
        var details: [String] = []
        if let current {
            let written = ByteCountFormatter.string(fromByteCount: max(0, current.bytes), countStyle: .file)
            if let total = current.total, total > 0 {
                details.append(
                    written + " of " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
            } else if current.bytes > 0 {
                details.append(written)
            }
            if current.phase == .downloading, current.work == nil, current.speed.isFinite, current.speed > 0 {
                let speed = Int64(min(current.speed, Double(Int64.max / 2)))
                details.append(ByteCountFormatter.string(fromByteCount: speed, countStyle: .file) + "/s")
            } else {
                details.append(stage)
            }
            let units: Int64
            if let work = current.work {
                units = max(finishingUnits[current.id] ?? 0, work.units)
            } else if let total = current.total, total > 0 {
                units = Int64(min(1, max(0, Double(current.bytes) / Double(total))) * 900_000)
            } else {
                units = 0
            }
            finishingUnits[current.id] = units
            let known = current.work != nil || (current.total ?? 0) > 0
            task.progress.totalUnitCount = known ? 1_000_000 : -1
            task.progress.completedUnitCount = known ? units : 0
        }
        task.update(title: current?.title ?? "Vesper Downloads", subtitle: details.joined(separator: " · "))
    }

    private func expired(_ identifier: String) {
        guard self.identifier == identifier, let task = systemTask else { return }
        self.identifier = nil; systemTask = nil; isGranted = false
        submission?.cancel(); submission = nil
        scheduler.cancel(identifier: identifier)
        members = []; finishingUnits = [:]; currentID = nil
        status = "Downloads paused. Resume to continue."
        Task { [onStop] in
            await onStop?()
            task.expirationHandler = nil
            task.complete(success: false)
        }
    }

    private func finish(success: Bool) {
        guard let identifier else { return }
        self.identifier = nil; isGranted = false
        submission?.cancel(); submission = nil
        scheduler.cancel(identifier: identifier)
        let task = systemTask; systemTask = nil
        if success, let task {
            task.progress.totalUnitCount = max(1, task.progress.totalUnitCount)
            task.progress.completedUnitCount = task.progress.totalUnitCount
        }
        task?.expirationHandler = nil; task?.complete(success: success)
        members = []; finishingUnits = [:]; currentID = nil; status = nil
    }
}
