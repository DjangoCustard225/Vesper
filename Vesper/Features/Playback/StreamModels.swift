import Foundation
import VesperCore
import UsenetEngine

struct VideoSelection: Identifiable {
    let id: String
    let title: String?
    let embedded: [StreamSource]?
    let episode: Episode?

    init(id: String, title: String?, embedded: [StreamSource]?, episode: Episode? = nil) {
        self.id = id
        self.title = title
        self.embedded = embedded
        self.episode = episode
    }

    init(episode: Episode) {
        self.init(
            id: episode.id, title: episode.label + " · " + episode.displayTitle,
            embedded: episode.streams, episode: episode)
    }
    /// A manual pack choice must never inherit a different episode's tracking identity.
    func matchingUsenetFile(_ file: UsenetVideo, episodes: [Episode]) -> VideoSelection? {
        func matches(_ episode: Episode) -> Bool {
            guard let season = episode.season, let number = episode.episode else { return false }
            return UsenetEpisodeTarget(
                season: season, episode: number,
                airDate: episode.released.map { String($0.prefix(10)) }
            ).matches(file)
        }
        if let episode, matches(episode) { return self }
        var seen = Set<String>()
        let matches = episodes.filter { seen.insert($0.id).inserted && matches($0) }
        return matches.count == 1 ? VideoSelection(episode: matches[0]) : nil
    }

}

/// Keep the truncated row title and its full-name sheet identical.
extension StreamOption {
    var displayName: String {
        if let release = nzbRelease { return release.title }
        if let filename = source.behaviorHints?.filename?.trimmingCharacters(in: .whitespacesAndNewlines),
            !filename.isEmpty
        {
            return filename
        }
        return (source.description ?? source.title ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? source.label.replacingOccurrences(of: "\n", with: " · ")
    }
}
