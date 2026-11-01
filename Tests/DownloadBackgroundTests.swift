import Foundation
import VesperCore

@MainActor final class TaskFixture: DownloadBackgroundTask {
    let progress = Progress(totalUnitCount: 0)
    var expirationHandler: (@Sendable () -> Void)?
    var completions: [Bool] = []
    var title = ""
    var subtitle = ""
    func update(title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
    func complete(success: Bool) { completions.append(success) }
}
@MainActor final class SchedulerFixture: DownloadBackgroundScheduling {
    enum Failure: Error { case denied }
    var handlers: [(String, @MainActor (any DownloadBackgroundTask) -> Void)] = []
    var cancelled: [String] = []
    var denied = false
    var submitted: CheckedContinuation<Void, Never>?
    func submit(identifier: String, launch: @escaping @MainActor (any DownloadBackgroundTask) -> Void)
        async throws
    {
        handlers.append((identifier, launch)); submitted?.resume(); submitted = nil
        if denied { throw Failure.denied }
    }
    func wait() async {
        if !handlers.isEmpty { return }
        await withCheckedContinuation { submitted = $0 }
    }
    func cancel(identifier: String) { cancelled.append(identifier) }
    func grant(_ task: TaskFixture, index: Int = 0) { handlers[index].1(task) }
}
@main @MainActor struct BackgroundRegression {
    static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func item(
            _ id: UUID = UUID(), phase: DownloadPhase = .downloading,
            total: Int64? = 1000, work: DownloadWorkProgress? = nil, bytes: Int64 = 500
        ) -> DownloadBackgroundItem {
            .init(id: id, title: "Movie", phase: phase, bytes: bytes, total: total, work: work, message: nil)
        }
        do {
            let scheduler = SchedulerFixture(), task = TaskFixture()
            let coordinator = DownloadBackgroundCoordinator(scheduler: scheduler)
            let first = item(), second = item(phase: .queued)
            coordinator.request(items: [first, second]); await scheduler.wait()
            check(!coordinator.isGranted, "Submission alone cannot authorize background work")
            scheduler.grant(task)
            scheduler.grant(task)
            check(task.completions.isEmpty, "Duplicate delivery cannot complete the active system task")
            check(
                coordinator.isGranted && task.progress.totalUnitCount == 1_000_000,
                "Grant shows the current download"
            )
            check(task.progress.completedUnitCount == 450_000, "Transfer progress reserves finishing work")
            coordinator.request(items: [first, second]); await Task.yield()
            check(scheduler.handlers.count == 1, "Adding work does not request another system activity")
            coordinator.update(
                items: [
                    item(first.id, phase: .completed),
                    item(second.id, work: .init(.extracting, fraction: 0.5)),
                ], force: true)
            check(
                task.progress.completedUnitCount > 900_000 && task.progress.completedUnitCount < 1_000_000,
                "Finishing work cannot report completion")
            coordinator.update(
                items: [item(first.id, phase: .completed), item(second.id, phase: .completed)], force: true)
            coordinator.update(items: [], force: true)
            check(task.progress.fractionCompleted == 1, "Only a committed queue reaches full system progress")
            check(task.completions == [true] && !coordinator.isGranted, "Completion is emitted exactly once")
        }
        do {
            let scheduler = SchedulerFixture(), task = TaskFixture()
            let coordinator = DownloadBackgroundCoordinator(scheduler: scheduler), value = item(total: nil)
            coordinator.request(items: [value]); await scheduler.wait(); scheduler.grant(task)
            check(task.progress.isIndeterminate, "Unknown file sizes remain indeterminate")
            coordinator.update(items: [item(value.id)], force: true)
            check(
                !task.progress.isIndeterminate && task.progress.completedUnitCount == 450_000,
                "Known sizes replace indeterminate progress")
            let restarted = DownloadBackgroundItem(
                id: value.id, title: "Movie", phase: .downloading,
                bytes: 0, total: 1000, work: nil, message: nil)
            coordinator.update(items: [restarted], force: true)
            check(
                task.progress.completedUnitCount == 0,
                "A restarted transfer reports real progress instead of appearing stalled")
            var stopped = false
            coordinator.onStop = { stopped = true }
            let expiration = task.expirationHandler
            expiration?(); expiration?()
            for _ in 0..<20 { await Task.yield() }
            check(stopped && !coordinator.isGranted, "Expiration revokes execution and pauses the queue")
            check(task.completions == [false], "Duplicate expiration does not finish the task twice")
        }
        do {
            let scheduler = SchedulerFixture(), task = TaskFixture()
            let coordinator = DownloadBackgroundCoordinator(scheduler: scheduler), value = item()
            var checkpoint: CheckedContinuation<Void, Never>?
            coordinator.onStop = { await withCheckedContinuation { checkpoint = $0 } }
            coordinator.request(items: [value]); await scheduler.wait(); scheduler.grant(task)
            task.expirationHandler?()
            for _ in 0..<30 where checkpoint == nil { await Task.yield() }
            check(
                checkpoint != nil && task.completions.isEmpty,
                "Expiration waits for the download checkpoint before completing")
            checkpoint?.resume()
            for _ in 0..<30 where task.completions.isEmpty { await Task.yield() }
            check(task.completions == [false], "Checkpoint completion releases the system task")
        }
        do {
            let scheduler = SchedulerFixture(), task = TaskFixture()
            let coordinator = DownloadBackgroundCoordinator(scheduler: scheduler)
            var first = item(), second = item()
            first.speed = 1024
            coordinator.request(items: [first, second]); await scheduler.wait(); scheduler.grant(task)
            check(
                task.title == "Movie" && task.subtitle.contains("/s"),
                "Activity shows title and transfer speed")
            check(
                task.subtitle.contains("500") && !task.subtitle.contains("complete"),
                "Activity shows bytes rather than queue count")
            coordinator.update(items: [second, first], force: true)
            check(task.subtitle.contains("/s"), "Reordering does not switch the displayed transfer")
            coordinator.update(items: [item(first.id, phase: .completed), second], force: true)
            check(!task.subtitle.contains("/s"), "Next transfer cannot inherit the previous speed")
            coordinator.update(items: [item(second.id, total: 0)], force: true)
            check(task.progress.isIndeterminate, "Zero totals are unknown rather than zero progress")
        }
        do {
            let scheduler = SchedulerFixture(); scheduler.denied = true
            let coordinator = DownloadBackgroundCoordinator(scheduler: scheduler), value = item()
            coordinator.request(items: [value]); await scheduler.wait()
            for _ in 0..<10 { await Task.yield() }
            check(
                !coordinator.isGranted && coordinator.status != nil,
                "Denial exposes a foreground fallback status")
            coordinator.update(items: [value], force: true)
            check(scheduler.handlers.count == 1, "Updates never retry a denied request")
        }
        do {
            let scheduler = SchedulerFixture(), late = TaskFixture()
            let coordinator = DownloadBackgroundCoordinator(scheduler: scheduler), value = item()
            coordinator.request(items: [value]); await scheduler.wait()
            coordinator.update(items: [item(value.id, phase: .completed)], force: true)
            scheduler.grant(late)
            check(
                !coordinator.isGranted && late.completions == [false],
                "A late grant cannot revive a completed queue")
        }
        do {
            let scheduler = SchedulerFixture(), task = TaskFixture()
            let coordinator = DownloadBackgroundCoordinator(scheduler: scheduler), value = item()
            coordinator.request(items: [value]); await scheduler.wait(); scheduler.grant(task)
            coordinator.update(items: [item(value.id, phase: .paused)], force: true)
            check(task.completions == [false], "A queue needing user input releases background time")
        }
        print("Passed \(checks) native download background lifecycle checks.")
    }
}
