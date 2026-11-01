import UIKit

/// Playback and downloads hold independent claims on the same system idle timer.
@MainActor enum ScreenAwake {
    static let downloads = UUID()
    private static var claims: Set<UUID> = []
    private static var original = false
    static func set(_ id: UUID, active: Bool) {
        if !active, !claims.contains(id) { return }
        if active {
            if claims.isEmpty { original = UIApplication.shared.isIdleTimerDisabled }
            claims.insert(id)
        } else {
            claims.remove(id)
        }
        UIApplication.shared.isIdleTimerDisabled = claims.isEmpty ? original : true
    }
}
