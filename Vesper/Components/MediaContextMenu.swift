import SwiftUI
import VesperCore

struct MediaContextMenu: ViewModifier {
    let item: MediaItem
    func body(content: Content) -> some View {
        content.contextMenu { MediaMenuActions(item: item) }
    }
}

struct MediaMenuActions: View {
    @Environment(AppStore.self) private var store
    let item: MediaItem
    var body: some View {
        Group {
            if WatchProgress.supports(item) {
                let watched = store.watchProgress.isWatched(item)
                Button(watched ? "Mark as Unwatched" : "Mark as Watched",
                       systemImage: watched ? "circle" : "checkmark.circle") {
                    store.setWatched(!watched, for: item)
                }
            }
            Button(store.contains(item) ? "Remove from Library" : "Add to Library",
                   systemImage: store.contains(item) ? "minus" : "plus") {
                store.toggleLibrary(item)
            }
        }
    }
}
