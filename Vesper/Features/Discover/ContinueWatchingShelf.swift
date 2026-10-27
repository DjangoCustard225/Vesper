import SwiftUI
import VesperCore

struct ContinueWatchingShelf: View {
    let records: [WatchRecord]
    @State private var prefetch = ArtworkPrefetchState()
    @State private var visible = false

    private var artworkItems: [MediaItem] {
        records.map { record in
            var item = record.media
            item.poster = item.background ?? item.poster
            return item
        }
    }

    private var urls: [URL] { visible ? prefetch.urls(artworkItems) : [] }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                ForEach(records, id: \.media.key) { record in
                    ContinueWatchingCard(record: record)
                        .onScrollVisibilityChange(threshold: 0.01) { active in
                            prefetch.visibility(active, key: record.media.key, items: artworkItems)
                        }
                }
            }.padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden).appScrollEdges()
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .prefetchArtwork(urls)
        .onDisappear {
            visible = false
            prefetch.reset()
        }
    }
}

private struct ContinueWatchingCard: View {
    @Environment(AppStore.self) private var store
    let record: WatchRecord

    private var media: MediaItem { record.media }

    private var progress: Double { min(1, max(0, record.elapsed / record.duration)) }

    private var playbackLabel: String {
        let minutes = Int(min(99_999, ceil(max(0, record.duration - record.elapsed) / 60)))
        let remaining = "\(minutes)m"
        guard let episode = record.episodeKey?.split(separator: ":"), episode.count == 2 else {
            return remaining
        }
        return "S\(episode[0]), E\(episode[1]) · " + remaining
    }

    var body: some View {
        NavigationLink {
            DetailView(item: media, startPlayback: true, resumeRecord: record)
        } label: {
            HomePlaybackCard(item: media, subtitle: playbackLabel, progress: progress)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(media.name)")
        .accessibilityValue(playbackLabel + " remaining")
        .contextMenu {
            MediaMenuActions(item: media)
            removeFromContinueWatching
        }
        .overlay(alignment: .bottomTrailing) {
            Menu {
                NavigationLink {
                    DetailView(item: media)
                } label: {
                    Label("View Details", systemImage: "info.circle")
                }
                MediaMenuActions(item: media)
                removeFromContinueWatching
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8)).frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.trailing, 6).padding(.bottom, 1)
                .accessibilityLabel("Options for \(media.name)")
        }
    }

    private var removeFromContinueWatching: some View {
        Button("Remove from Continue Watching", systemImage: "minus.circle") {
            store.removeFromContinueWatching(media)
        }
    }
}
