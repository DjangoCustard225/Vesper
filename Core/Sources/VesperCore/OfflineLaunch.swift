import Foundation

/// Choose the initial root once. Reconnection is explicit so it cannot dismiss offline playback.
public struct OfflineLaunch: Sendable {
    public enum Mode: Sendable { case waiting, online, offline }
    public private(set) var mode = Mode.waiting
    public init() {}
    public mutating func observe(available: Bool) {
        guard mode == .waiting else { return }
        mode = available ? .online : .offline
    }
    public mutating func goOnline(available: Bool) {
        if available, mode == .offline { mode = .online }
    }
}

public enum LibraryDownloadPresentation {
    public static func titles(saved: [MediaItem], downloads: [DownloadRecord], offlineOnly: Bool)
        -> [MediaItem]
    {
        let relevant = offlineOnly ? downloads.filter { $0.phase == .completed } : downloads
        return MediaIdentity.unique((offlineOnly ? [] : saved) + relevant.map(\.media))
    }
}
