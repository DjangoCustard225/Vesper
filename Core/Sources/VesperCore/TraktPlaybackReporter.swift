#if !VESPER_GO
import Foundation

public struct TraktPlaybackSample: Equatable, Sendable {
    public let elapsed: Double
    public let duration: Double
    public let playing: Bool
    public let buffering: Bool
    public let ended: Bool

    public init(elapsed: Double, duration: Double, playing: Bool, buffering: Bool, ended: Bool) {
        self.elapsed = elapsed
        self.duration = duration
        self.playing = playing
        self.buffering = buffering
        self.ended = ended
    }
}

public struct TraktScrobbleEvent: Sendable {
    public let sessionID: UUID
    public let action: TraktScrobbleAction
    public let progress: Double
}

/// Emits lifecycle transitions, not periodic network heartbeats or temporary buffering transitions.
public struct TraktPlaybackReporter: Sendable {
    private var lastAction: TraktScrobbleAction?
    private var lastProgress: Double = 0
    private var finished = false
    private var sessionID = UUID()

    public init() {}

    public mutating func update(_ sample: TraktPlaybackSample) -> TraktScrobbleEvent? {
        guard sample.duration.isFinite, sample.duration > 0, sample.elapsed.isFinite, sample.elapsed >= 0
        else {
            return nil
        }
        if finished {
            // A deliberate replay starts a fresh watching cycle after completion.
            guard sample.playing, !sample.ended, sample.elapsed / sample.duration < 0.8 else { return nil }
            finished = false
            lastAction = nil
            sessionID = UUID()
        }
        lastProgress = min(100, max(0, sample.elapsed / sample.duration * 100))
        if sample.ended { lastProgress = 100; return finish() }
        guard !sample.buffering, sample.elapsed >= 5 else { return nil }
        let action: TraktScrobbleAction = sample.playing ? .start : .pause
        guard action != lastAction, sample.playing || lastAction != nil else { return nil }
        lastAction = action
        return TraktScrobbleEvent(sessionID: sessionID, action: action, progress: lastProgress)
    }

    public mutating func finish() -> TraktScrobbleEvent? {
        guard !finished, lastAction != nil else { return nil }
        finished = true
        lastAction = .stop
        return TraktScrobbleEvent(sessionID: sessionID, action: .stop, progress: lastProgress)
    }
}

/// Serializes delivery while replacing unsent transitions with the latest state of each session.
/// Completed watches remain durable in the account's existing history outbox.
@MainActor public final class TraktScrobbleDelivery {
    private struct Pending {
        let id = UUID()
        let event: TraktScrobbleEvent
        let send: @MainActor () async throws -> Void
        let succeeded: @MainActor () -> Void
        let failed: @MainActor (Error) -> Void
        var attempts = 0
    }

    private var pending: [Pending] = []
    private var closedSessions: [UUID] = []
    private var worker: (id: UUID, task: Task<Void, Never>)?
    private let maximumAttempts: Int
    private let baseDelay: TimeInterval
    private let wait: @MainActor (Duration) async throws -> Void

    public init(
        maximumAttempts: Int = 3, baseDelay: TimeInterval = 15,
        wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseDelay = max(0, baseDelay)
        self.wait = wait
    }

    public func submit(
        _ event: TraktScrobbleEvent,
        send: @escaping @MainActor () async throws -> Void,
        succeeded: @escaping @MainActor () -> Void,
        failed: @escaping @MainActor (Error) -> Void
    ) {
        guard !closedSessions.contains(event.sessionID) else { return }
        if event.action == .stop {
            closedSessions.append(event.sessionID)
            closedSessions = Array(closedSessions.suffix(256))
        }
        let value = Pending(event: event, send: send, succeeded: succeeded, failed: failed)
        if let index = pending.firstIndex(where: { $0.event.sessionID == event.sessionID }) {
            pending[index] = value
        } else {
            pending.append(value)
        }
        guard worker == nil else { return }
        let id = UUID()
        worker = (id, Task { await self.deliver(id: id) })
    }

    public func cancel() {
        worker?.task.cancel()
        worker = nil
        pending = []
        closedSessions = []
    }

    public func flush() async {
        while let worker { await worker.task.value }
    }

    private func deliver(id: UUID) async {
        defer { if worker?.id == id { worker = nil } }
        while worker?.id == id, !Task.isCancelled, let value = pending.first {
            do {
                try await value.send()
                guard worker?.id == id, !Task.isCancelled else { return }
                if pending.first?.id == value.id { pending.removeFirst() }
                value.succeeded()
            } catch {
                guard worker?.id == id, !Task.isCancelled else { return }
                if error is CancellationError {
                    if pending.first?.id == value.id { pending.removeFirst() }
                    continue
                }
                value.failed(error)
                let attempt = value.attempts + 1
                if pending.first?.id == value.id { pending[0].attempts = attempt }
                guard let delay = retryDelay(error, attempt: attempt) else {
                    if pending.first?.id == value.id { pending.removeFirst() }
                    continue
                }
                do { try await wait(.seconds(delay)) } catch { return }
            }
        }
    }

    private func retryDelay(_ error: Error, attempt: Int) -> TimeInterval? {
        guard attempt < maximumAttempts else { return nil }
        if case TraktError.rateLimited(let seconds) = error { return max(1, seconds) }
        if case TraktError.http(let status) = error {
            guard [408, 500, 502, 503, 504].contains(status) else { return nil }
        } else if let error = error as? URLError {
            guard
                [
                    URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                ].contains(error.code)
            else { return nil }
        } else {
            return nil
        }
        return min(300, baseDelay * pow(2, Double(attempt - 1)))
    }
}
#endif
