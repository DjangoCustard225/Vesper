import Foundation
import VesperCore

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
