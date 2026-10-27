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
