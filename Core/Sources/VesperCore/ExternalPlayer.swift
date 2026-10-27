import Foundation

public enum VideoPlayer: String, CaseIterable, Identifiable, Codable, Sendable {
    case aether
    case vlc, infuse, outplayer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .aether: "AVPlayer"
        case .vlc: "VLC"
        case .infuse: "Infuse"
        case .outplayer: "Outplayer"
        }
    }
    public var isInternal: Bool { self == .aether }

    public static var externalPlayers: [VideoPlayer] { [.vlc, .infuse, .outplayer] }

    public var detectionURL: URL? {
        switch self {
        case .vlc: URL(string: "vlc-x-callback://x-callback-url/stream")
        case .infuse: URL(string: "infuse://x-callback-url/play")
        case .outplayer: URL(string: "outplayer://x-callback-url/play")
        case .aether: nil
        }
    }

    public static func availablePlayers(
        _ candidates: [VideoPlayer], showAllExternalPlayers: Bool = false, canOpen: (URL) -> Bool
    ) -> [VideoPlayer] {
        // A container host can deny scheme queries even when opening the URL succeeds.
        // Manual selection must not depend on that query result.
        if showAllExternalPlayers { return candidates }
        return candidates.filter { $0.detectionURL.map(canOpen) ?? true }
    }

    public func availablePreference(in players: [VideoPlayer]) -> VideoPlayer {
        if players.contains(self) { return self }
        return players.first(where: { $0 == .infuse })
            ?? players.first(where: { $0.detectionURL != nil }) ?? players.first ?? self
    }
    public static func preferred(storedValue: String?) -> VideoPlayer {
        storedValue.flatMap(VideoPlayer.init(rawValue:)) ?? .aether
    }

    public func launchURL(for stream: URL) throws -> URL {
        _ = try AddonURL.http(stream.absoluteString)
        guard let target = detectionURL,
            var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        else {
            throw AddonError.unsupportedStream
        }
        let items = [URLQueryItem(name: "url", value: stream.absoluteString)]
        // Encode nested URLs completely, preserving signed queries, percent escapes and '+' values.
        components.percentEncodedQuery = items.map {
            AddonURL.encode($0.name) + "=" + AddonURL.encode($0.value ?? "")
        }.joined(separator: "&")
        guard let url = components.url else { throw AddonError.invalidURL }
        return url
    }
}

public enum AddonPolicy {
    public static func isCinemeta(_ addon: InstalledAddon) -> Bool {
        addon.manifest.id.lowercased() == "com.linvo.cinemeta"
            || addon.manifestURL.host?.lowercased() == "v3-cinemeta.strem.io"
    }
}
