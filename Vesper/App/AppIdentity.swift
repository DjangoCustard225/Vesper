import VesperCore
import UIKit

enum AppIdentity {
    static let displayName = "Vesper"
    static let bundleID = "app.vesper"
    static let filePrefix = "Vesper"
    static let urlSchemes = ["vesper", "swiftstream"]
    static let players = VideoPlayer.allCases

    // Discovery must be read-only; attempting to open each URL would launch the installed players.
    @diagnose(DeprecatedDeclaration, as: ignored)
    @MainActor static func detectedPlayers(showAllExternalPlayers: Bool) -> [VideoPlayer] {
        VideoPlayer.availablePlayers(players, showAllExternalPlayers: showAllExternalPlayers) {
            UIApplication.shared.canOpenURL($0)
        }
    }
}
