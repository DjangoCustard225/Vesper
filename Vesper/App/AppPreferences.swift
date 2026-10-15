import Foundation
import VesperCore

#if !VESPER_GO
struct PlayerGesturePreferences: Codable, Equatable {
    var holdFor2x = true
    var brightnessSwipe = true
    var volumeSwipe = true
}
#endif

enum AppPreferenceStorage {
    static func preferredPlayer(in defaults: UserDefaults = .standard) -> VideoPlayer {
        VideoPlayer.preferred(storedValue: defaults.string(forKey: "preferredPlayer"))
    }

    static func save(_ player: VideoPlayer, in defaults: UserDefaults = .standard) {
        defaults.set(player.rawValue, forKey: "preferredPlayer")
    }

    #if !VESPER_GO
    static func gestures(in defaults: UserDefaults = .standard) -> PlayerGesturePreferences {
        defaults.data(forKey: "playerGestures")
            .flatMap { try? JSONDecoder().decode(PlayerGesturePreferences.self, from: $0) }
            ?? PlayerGesturePreferences()
    }

    static func save(_ gestures: PlayerGesturePreferences, in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(gestures) { defaults.set(data, forKey: "playerGestures") }
    }

    static func showContinueWatching(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "showContinueWatching") as? Bool ?? true
    }

    static func saveContinueWatching(_ visible: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: "showContinueWatching")
    }

    static func removeRetiredPreferences(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "automaticallyOpenLastStream")
    }
    #endif
}
