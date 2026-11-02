import Foundation
import VesperCore

enum TrackingService: String, CaseIterable, Identifiable {
    case none, trakt, simkl
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None";
        case .trakt: "Trakt";
        case .simkl: "SIMKL"
        }
    }
    static var current: Self {
        if let value = UserDefaults.standard.string(forKey: "activeTrackingService") {
            return Self(rawValue: value) ?? .trakt
        }
        let trakt = (try? SecureStorage.load(.traktTokens)) != nil
        let simkl = (try? SecureStorage.load(.simklTokens)) != nil
        return trakt ? .trakt : (simkl ? .simkl : .trakt)
    }
}
