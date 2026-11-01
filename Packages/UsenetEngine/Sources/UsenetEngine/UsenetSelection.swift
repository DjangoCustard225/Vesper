import Foundation

public struct UsenetEpisodeTarget: Sendable {
    public let season: Int
    public let episode: Int
    public let airDate: String?
    public init(season: Int, episode: Int, airDate: String? = nil) {
        self.season = season; self.episode = episode; self.airDate = airDate
    }
    public func matches(_ video: UsenetVideo) -> Bool {
        guard season >= 0, episode > 0, video.name.utf8.count <= 4096 else { return false }
        let name = (video.name as NSString).lastPathComponent
        if name.range(of: #"(?i)(?:^|[ ._-])(?:sample|proof)(?:[ ._-]|$)"#, options: .regularExpression)
            != nil
        {
            return false
        }
        let pattern =
            "(?i)(?<![a-z0-9])(?:s0*\(season)[ ._-]*e0*\(episode)|0*\(season)x0*\(episode))(?![0-9])"
        if name.range(of: pattern, options: .regularExpression) != nil { return true }
        guard let airDate, airDate.count == 10,
            airDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else { return false }
        let normalized = name.replacingOccurrences(of: ".", with: "-").replacingOccurrences(
            of: "_", with: "-")
        return normalized.contains(airDate)
    }
}
