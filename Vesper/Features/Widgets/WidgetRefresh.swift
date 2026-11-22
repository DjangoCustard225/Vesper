import BackgroundTasks
import Foundation

/// The scheduler callback transfers ownership to the main actor before the task is used.
private final class WidgetRefreshTaskBox: @unchecked Sendable {
    let value: BGAppRefreshTask
    init(_ value: BGAppRefreshTask) { self.value = value }
}

/// Keeps the widgets current while Vesper isn't open: pulls watch progress from Trakt or SIMKL and
/// the sync folder, and looks for newly aired episodes.
/// iOS decides when this runs, based on how often Vesper is used.
@MainActor
enum WidgetRefresh {
    static let identifier = "app.vesper.widgets.refresh"
    private static let interval: TimeInterval = 3 * 3600

    /// Must run before the app finishes launching.
    static func register(store: AppStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) {
            [weak store] task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let box = WidgetRefreshTaskBox(task)
            MainActor.assumeIsolated {
                guard let store else {
                    box.value.setTaskCompleted(success: false)
                    return
                }
                run(box, store: store)
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        // Fails in the simulator and when background refresh is off; the widgets then update on launch.
        Task { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
    }

    private static func run(_ box: WidgetRefreshTaskBox, store: AppStore) {
        schedule()
        let work = Task { @MainActor in
            switch store.activeTrackingService {
            case .trakt: await store.syncTrakt()
            case .simkl: await store.syncSimkl()
            case .none: break
            }
            await store.folderSync.syncAndWait(store: store)
            await WidgetPublisher.shared.publish(store: store, refreshUpNext: true)
            await store.flushWatchProgress()
            await store.flushLibrary()
            box.value.setTaskCompleted(success: !Task.isCancelled)
        }
        box.value.expirationHandler = { work.cancel() }
    }
}
