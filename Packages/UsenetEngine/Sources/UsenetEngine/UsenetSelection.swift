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

extension NZBManifest {
    /// Narrows a season pack only when the NZB itself identifies a unique episode.
    /// Ambiguous and shared archives keep their complete manifest for safe extraction.
    public func filesForEpisode(_ target: UsenetEpisodeTarget) -> [NZBFile] {
        func matches(_ name: String) -> Bool {
            target.matches(UsenetVideo(id: 0, name: name, extents: []))
        }
        let supportedVideoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts"]
        let videos = files.filter {
            supportedVideoExtensions.contains(($0.name as NSString).pathExtension.lowercased())
        }
        let matchedVideos = videos.filter { matches($0.name) }
        if videos.count > 1 { return matchedVideos.count == 1 ? matchedVideos : files }

        // New-style RAR parts must have a complete, distinct filename prefix for each set.
        guard let expression = try? NSRegularExpression(pattern: #"(?i)^(.*)\.part(\d+)\.rar$"#) else {
            return files
        }
        var groups: [String: [(Int, NZBFile)]] = [:]
        for file in files {
            let name = (file.name as NSString).lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard let match = expression.firstMatch(in: name, range: range),
                let prefixRange = Range(match.range(at: 1), in: name),
                let numberRange = Range(match.range(at: 2), in: name),
                let number = Int(name[numberRange]), number > 0
            else { continue }
            groups[String(name[prefixRange]).lowercased(), default: []].append((number, file))
        }
        let matchedGroups = groups.filter { matches($0.key) }
        guard groups.count > 1, matchedGroups.count == 1, let parts = matchedGroups.first?.value else {
            return files
        }
        let ordered = parts.sorted { $0.0 < $1.0 }
        guard ordered.enumerated().allSatisfy({ $0.element.0 == $0.offset + 1 }) else { return files }
        return ordered.map(\.1)
    }
}
