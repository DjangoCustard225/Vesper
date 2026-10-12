import Foundation
import Observation

final class CAMetalLayer: @unchecked Sendable {}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    static let didEnterBackgroundNotification = Notification.Name("background")
    static let willEnterForegroundNotification = Notification.Name("foreground")
    var isIdleTimerDisabled = false
}
let AVAudioSessionRouteChangeReasonKey = "routeReason"
@MainActor final class AVAudioSession {
    enum Category { case playback }
    enum Mode { case moviePlayback }
    enum RouteChangeReason: UInt { case oldDeviceUnavailable = 2 }
    struct SetActiveOptions: OptionSet {
        let rawValue: Int
        static let notifyOthersOnDeactivation = Self(rawValue: 1)
    }
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    static let didBecomeInactiveNotification = Notification.Name("inactive")
    static let routeChangeNotification = Notification.Name("route")
    func setCategory(_ category: Category, mode: Mode) throws {}
    func setActive(_ active: Bool, options: SetActiveOptions = []) throws {}
}
final class MPVSession: @unchecked Sendable {
    static var latest: MPVSession!
    private let receive: @Sendable (MPVPlaybackEvent) -> Void
    var operations: [String] = []
    var rates: [Float] = []
    var seeks: [Double] = []
    init(layer: CAMetalLayer, receive: @escaping @Sendable (MPVPlaybackEvent) -> Void) {
        self.receive = receive; Self.latest = self
    }
    func start(url: URL) { operations.append("start") }
    func pause(_ paused: Bool) { operations.append("pause:\(paused)") }
    func rate(_ value: Float) { rates.append(value); operations.append("rate:\(value)") }
    func seek(_ value: Double) { seeks.append(value); operations.append("seek") }
    func select(track: Int32, subtitle: Bool) { operations.append("\(subtitle ? "sid" : "aid"):\(track)") }
    func fill(_ fill: Bool) { operations.append("fill:\(fill)") }
    func suspendVideo(_ suspended: Bool) { operations.append("video:\(suspended)") }
    func stop() { operations.append("stop") }
    func emit(_ snapshot: MPVSnapshot) { receive(.state(snapshot)) }
    func fail() { receive(.failure("Test source failure")) }
}
