import VesperCore
import UIKit

enum AppIdentity {
    #if VESPER_GO
    static let displayName = "Vesper Go"
    static let bundleID = "app.vesper.go"
    static let filePrefix = "VesperGo"
    static let urlSchemes = ["vespergo"]
    static let players = VideoPlayer.externalPlayers
    #else
    static let displayName = "Vesper"
    static let bundleID = "app.vesper"
    static let filePrefix = "Vesper"
    static let urlSchemes = ["vesper", "swiftstream"]
    static let players = VideoPlayer.allCases
    #endif

    // Discovery must be read-only; attempting to open each URL would launch the installed players.
    @diagnose(DeprecatedDeclaration, as: ignored)
    @MainActor static func detectedPlayers(showAllExternalPlayers: Bool) -> [VideoPlayer] {
        VideoPlayer.availablePlayers(players, showAllExternalPlayers: showAllExternalPlayers) {
            UIApplication.shared.canOpenURL($0)
        }
    }
}
