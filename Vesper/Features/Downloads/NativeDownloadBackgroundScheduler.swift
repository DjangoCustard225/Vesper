import BackgroundTasks
import Foundation

/// The scheduler callback transfers ownership to the UI actor before the task is used.
private final class NativeDownloadTaskBox: @unchecked Sendable {
    let value: BGContinuedProcessingTask
    init(_ value: BGContinuedProcessingTask) { self.value = value }
}

@MainActor private final class NativeDownloadBackgroundTask: DownloadBackgroundTask {
    private let task: BGContinuedProcessingTask
    private var completed = false
    init(_ task: BGContinuedProcessingTask) { self.task = task }
    var progress: Progress { task.progress }
    var expirationHandler: (@Sendable () -> Void)? {
        didSet { task.expirationHandler = expirationHandler }
    }
    func update(title: String, subtitle: String) { task.updateTitle(title, subtitle: subtitle) }
    func complete(success: Bool) {
        guard !completed else { return }
        completed = true; task.setTaskCompleted(success: success)
    }
}

@MainActor final class NativeDownloadBackgroundScheduler: DownloadBackgroundScheduling {
    func submit(identifier: String, launch: @escaping @MainActor (any DownloadBackgroundTask) -> Void)
        async throws
    {
        guard
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier, using: .main,
                launchHandler: { task in
                    guard let task = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false); return
                    }
                    let box = NativeDownloadTaskBox(task)
                    Task { @MainActor in launch(NativeDownloadBackgroundTask(box.value)) }
                })
        else { throw CocoaError(.featureUnsupported) }
        let submission = Task.detached {
            try Task.checkCancellation()
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier, title: "Vesper Downloads", subtitle: "Preparing downloads…")
            request.strategy = .queue
            try await BGTaskScheduler.shared.submitTaskRequest(request)
            if Task.isCancelled {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                throw CancellationError()
            }
        }
        try await withTaskCancellationHandler {
            try await submission.value
        } onCancel: {
            submission.cancel()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }
    func cancel(identifier: String) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
}
