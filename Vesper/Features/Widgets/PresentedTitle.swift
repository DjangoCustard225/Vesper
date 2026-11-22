import Foundation
import VesperCore

/// A title page shown over the tabs, from Search or from a widget link.
struct PresentedTitle: Identifiable {
    let id = UUID()
    let item: MediaItem
    var startPlayback = false
    var resumeRecord: WatchRecord?

    init(item: MediaItem, startPlayback: Bool = false, resumeRecord: WatchRecord? = nil) {
        self.item = item
        self.startPlayback = startPlayback
        self.resumeRecord = resumeRecord
    }

    /// Reads `vesper://title`, `vesper://resume` and `vesper://play` links.
    /// Returns nil when there's nothing to open, such as resuming with nothing in progress.
    @MainActor init?(widgetURL url: URL, store: AppStore) {
        guard let action = url.host.flatMap(WidgetLink.Action.init(rawValue:)) else { return nil }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let key = value("key")

        if action == .resume {
            let continuing = store.watchProgress.continueWatching
            if let record = key.map({ key in continuing.first { $0.media.key == key } }) ?? continuing.first {
                self.init(item: record.media, startPlayback: true, resumeRecord: record)
                return
            }
            // Finished or removed since the widget last updated: start from the title instead.
        }
        // The stored title carries the IDs and artwork the link leaves out.
        if let stored = store.watchProgress.records.first(where: { $0.media.key == key })?.media
            ?? store.library.items.first(where: { $0.key == key })
        {
            self.init(item: stored, startPlayback: action != .title)
            return
        }
        // Not one of this device's titles. Any app or website can open these links, so they only open
        // the title page, never start playback, and use artwork only when Vesper's widget shows it.
        guard let id = value("id"), !id.isEmpty, let type = value("type"), ["movie", "series"].contains(type)
        else { return nil }
        let poster = value("poster").flatMap { poster in Self.widgetPosters().contains(poster) ? poster : nil
        }
        self.init(item: MediaItem(id: id, type: type, name: value("name") ?? "", poster: poster))
    }

    /// Poster addresses the widgets currently show.
    private static func widgetPosters() -> Set<String> {
        let shelf = WidgetShelf.load()
        let items = shelf.continueWatching + shelf.upNext + shelf.library + shelf.catalogs.flatMap(\.items)
        return Set(items.compactMap(\.posterURL))
    }
}
