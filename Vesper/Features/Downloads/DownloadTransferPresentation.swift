import Foundation
import VesperCore

/// Read-only presentation shared by the featured download and compact queue rows.
struct DownloadTransferPresentation {
    enum Action {
        case pause, resume, retry, play, chooseVideo, enterPassword
        var title: String {
            switch self {
            case .pause: "Pause"
            case .resume: "Resume"
            case .retry: "Retry"
            case .play: "Play"
            case .chooseVideo: "Choose Video"
            case .enterPassword: "Enter Password"
            }
        }
        var symbol: String {
            switch self {
            case .pause: "pause.fill"
            case .resume, .play: "play.fill"
            case .retry: "arrow.clockwise"
            case .chooseVideo: "film.stack"
            case .enterPassword: "lock"
            }
        }
    }
    let record: DownloadRecord
    var action: Action {
        if record.usenetFiles?.isEmpty == false { return .chooseVideo }
        if record.usenetNeedsPassword == true { return .enterPassword }
        switch record.phase {
        case .completed: return .play
        case .failed: return .retry
        case .paused: return .resume
        default: return .pause
        }
    }
    var supportingMessage: String? {
        record.phase == .failed || action == .chooseVideo || action == .enterPassword ? record.message : nil
    }
    var filename: String? {
        [record.source.behaviorHints?.filename, record.source.title, record.source.description]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
    func status(networkAvailable: Bool, canTransfer: Bool, work: DownloadWorkProgress?) -> String {
        switch record.phase {
        case .completed: return "Downloaded"
        case .failed: return "Needs attention"
        case .paused: return "Paused"
        case .pausing: return "Pausing…"
        case .preparing: return "Preparing…"
        case .queued:
            if !networkAvailable { return "Waiting for connection" }
            if !canTransfer { return "Waiting for Wi-Fi" }
            return record.message ?? "Queued"
        case .downloading: return work?.stage.title ?? record.message ?? "Downloading"
        }
    }
    func fraction(bytes: Int64, total: Int64?, work: DownloadWorkProgress?) -> Double? {
        if record.phase == .completed { return 1 }
        if let work { return Double(work.units) / 1_000_000 }
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(bytes) / Double(total))) * 0.9
    }
    static func preferredID(in records: [DownloadRecord], keeping selection: UUID?) -> UUID? {
        if let selection, records.contains(where: { $0.id == selection }) { return selection }
        let order: [DownloadPhase] = [
            .downloading, .preparing, .queued, .failed, .paused, .pausing, .completed,
        ]
        for phase in order {
            if let record = records.first(where: { $0.phase == phase }) { return record.id }
        }
        return nil
    }
}
