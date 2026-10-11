import Foundation

public enum VideoPlayer: String, CaseIterable, Identifiable, Codable, Sendable {
    case vlc, infuse
    public var id: String { rawValue }
    public var title: String { switch self { case .vlc: "VLC"; case .infuse: "Infuse" } }
    public static func preferred(storedValue: String?) -> VideoPlayer {
        storedValue.flatMap(VideoPlayer.init(rawValue:)) ?? .vlc
    }
    public func launchURL(for stream: URL) throws -> URL {
        _ = try AddonURL.http(stream.absoluteString)
        var components = URLComponents()
        components.scheme = self == .vlc ? "vlc-x-callback" : "infuse"
        components.host = "x-callback-url"
        components.path = self == .vlc ? "/stream" : "/play"
        let items = [URLQueryItem(name: "url", value: stream.absoluteString)]
        // Encode nested URLs completely, preserving signed queries, percent escapes and '+' values.
        components.percentEncodedQuery = items.map { AddonURL.encode($0.name) + "=" + AddonURL.encode($0.value ?? "") }.joined(separator: "&")
        guard let url = components.url else { throw AddonError.invalidURL }
        return url
    }
}

public enum AddonPolicy {
    public static func isCinemeta(_ addon: InstalledAddon) -> Bool {
        addon.manifest.id.lowercased() == "com.linvo.cinemeta" ||
        addon.manifestURL.host?.lowercased() == "v3-cinemeta.strem.io"
    }
}
