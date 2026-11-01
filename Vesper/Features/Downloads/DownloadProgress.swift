import Foundation
import Observation
import VesperCore

@MainActor @Observable final class DownloadProgress {
    var bytes: Int64 = 0
    var total: Int64?
    var speed: Double = 0
    var connections: Int = 0
    var work: DownloadWorkProgress?
    @ObservationIgnored private var sample: (Int64, TimeInterval)?
    var fraction: Double? { total.flatMap { $0 > 0 ? min(1, max(0, Double(bytes) / Double($0))) : nil } }
    var currentSpeed: Double {
        sample.map { ProcessInfo.processInfo.systemUptime - $0.1 < 4 ? speed : 0 } ?? 0
    }
    var remaining: Double? {
        total.flatMap { currentSpeed > 0 ? Double(max(0, $0 - bytes)) / currentSpeed : nil }
    }
    func update(_ written: Int64, total: Int64?) {
        let now = ProcessInfo.processInfo.systemUptime
        if let sample, written < sample.0 { speed = 0 }
        if let sample, now > sample.1, written >= sample.0 {
            let instant = Double(written - sample.0) / (now - sample.1)
            speed = speed == 0 ? instant : speed * 0.65 + instant * 0.35
        }
        bytes = written
        self.total = total
        sample = (written, now)
    }
    func reset(bytes: Int64, total: Int64?) {
        self.bytes = bytes; self.total = total; speed = 0; sample = nil; work = nil
    }
}
