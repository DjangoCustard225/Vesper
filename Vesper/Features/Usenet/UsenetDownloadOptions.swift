import Foundation
import Observation

@MainActor @Observable final class UsenetDownloadOptions {
    static let shared = UsenetDownloadOptions()
    var bandwidthKBps: Int {
        didSet { UserDefaults.standard.set(max(0, bandwidthKBps), forKey: "usenetBandwidthKBps") }
    }
    var repair: Bool { didSet { UserDefaults.standard.set(repair, forKey: "usenetRepair") } }
    var keepAwake: Bool { didSet { UserDefaults.standard.set(keepAwake, forKey: "usenetKeepAwake") } }
    var notifications: Bool {
        didSet { UserDefaults.standard.set(notifications, forKey: "usenetNotifications") }
    }
    private init() {
        let defaults = UserDefaults.standard
        bandwidthKBps = min(1_000_000, max(0, defaults.integer(forKey: "usenetBandwidthKBps")))
        repair = defaults.object(forKey: "usenetRepair") as? Bool ?? true
        keepAwake = defaults.object(forKey: "usenetKeepAwake") as? Bool ?? true
        notifications = defaults.bool(forKey: "usenetNotifications")
    }
}
