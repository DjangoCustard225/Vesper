import Foundation

public struct DownloadWorkProgress: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case verifying, repairing, extracting, saving, assembling
        public var title: String {
            switch self {
            case .verifying: "Verifying files…"
            case .repairing: "Repairing files…"
            case .extracting: "Extracting archive…"
            case .saving: "Saving video…"
            case .assembling: "Assembling video…"
            }
        }
        fileprivate var window: (Double, Double) {
            switch self {
            case .verifying: (0.90, 0.03)
            case .repairing: (0.93, 0.04)
            case .extracting: (0.97, 0.025)
            case .saving: (0.995, 0.004)
            case .assembling: (0.90, 0.099)
            }
        }
    }
    public let stage: Stage
    public let fraction: Double
    public init(_ stage: Stage, fraction: Double = 0) {
        self.stage = stage
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
    }
    public var units: Int64 {
        let (start, length) = stage.window
        return min(999_999, Int64((start + length * fraction) * 1_000_000))
    }
}

/// Synchronous workers can report often without flooding the UI actor with tasks.
public final class DownloadWorkReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: DownloadWorkProgress?
    private var last: TimeInterval = 0
    private let report: @Sendable (DownloadWorkProgress) -> Void
    public init(report: @escaping @Sendable (DownloadWorkProgress) -> Void) { self.report = report }
    public func update(_ value: DownloadWorkProgress) {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let emit =
            previous != value && (previous?.stage != value.stage || now - last >= 1 || value.fraction == 1)
        if emit { previous = value; last = now }
        lock.unlock()
        if emit { report(value) }
    }
}
