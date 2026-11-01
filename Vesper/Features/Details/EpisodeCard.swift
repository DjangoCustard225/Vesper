import SwiftUI
import VesperCore

struct EpisodeShelf: View {
    let media: MediaItem
    let episodes: [Episode]
    var initialEpisodeID: String? = nil
    let play: (Episode) -> Void
    var chooseOnline: ((Episode) -> Void)? = nil
    var download: ((Episode) -> Void)? = nil
    let showDescription: (Episode) -> Void
    @State private var position = ScrollPosition(idType: String.self, edge: .leading)
    @State private var prefetch = ArtworkPrefetchState()
    @State private var visible = false

    private var artworkItems: [MediaItem] {
        episodes.map {
            MediaItem(
                id: $0.id, type: "episode", name: $0.displayTitle,
                poster: $0.thumbnail ?? media.background ?? media.poster)
        }
    }

    private var urls: [URL] { visible ? prefetch.urls(artworkItems) : [] }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(episodes) { episode in
                    EpisodeCard(
                        media: media, episode: episode,
                        play: { play(episode) }, showDescription: { showDescription(episode) },
                        chooseOnline: chooseOnline.map { action in { action(episode) } },
                        download: download.map { action in { action(episode) } }
                    )
                    .id(episode.id)
                    .onScrollVisibilityChange(threshold: 0.01) { active in
                        prefetch.visibility(active, key: "episode:" + episode.id, items: artworkItems)
                    }
                }
            }.scrollTargetLayout()
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollPosition($position, anchor: .leading)
        .defaultScrollAnchor(.leading, for: .initialOffset)
        .scrollIndicators(.hidden).appScrollEdges()
        .task(id: episodes.first { $0.id == initialEpisodeID }?.id) {
            guard let id = initialEpisodeID, episodes.contains(where: { $0.id == id }) else { return }
            // Position this horizontal scroll view only, keeping the surrounding detail page still.
            position.scrollTo(id: id, anchor: .leading)
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        .prefetchArtwork(urls)
        .onDisappear {
            visible = false
            prefetch.reset()
        }
    }
}

struct EpisodeCard: View {
    @Environment(AppStore.self) private var store
    let media: MediaItem
    let episode: Episode
    let play: () -> Void
    let showDescription: () -> Void
    var chooseOnline: (() -> Void)? = nil
    var download: (() -> Void)? = nil
    @ScaledMetric(relativeTo: .body) private var cardWidth = 240.0
    @ScaledMetric(relativeTo: .body) private var cardHeight = 248.0

    private var watched: Bool { store.isWatched(media, episode: episode) }
    private var downloaded: Bool {
        store.downloads.completed.contains {
            DownloadPlayback.matches($0, media: media, videoID: episode.id, episode: episode)
        }
    }

    private var playbackLabel: String {
        if let runtime = episode.runtimeMinutes { return "\(runtime)m" }
        return "Play"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Button(action: play) {
                ZStack(alignment: .bottomLeading) {
                    Artwork(url: episode.thumbnail ?? media.background ?? media.poster)
                        .frame(width: cardWidth, height: cardHeight)
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.episode.map { "EPISODE \($0)" } ?? "EPISODE")
                            .font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        Text(episode.displayTitle).font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(episode.overview ?? "")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineSpacing(2)
                            .lineLimit(3, reservesSpace: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 58)
                    .background {
                        Rectangle().fill(.ultraThinMaterial)
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .black, location: 0.25),
                                    ], startPoint: .top, endPoint: .bottom)
                            )
                            .padding(.top, -24)
                    }
                }.frame(width: cardWidth, height: cardHeight).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(episode.label), \(episode.displayTitle)")
                .accessibilityValue(
                    [watched ? "Watched" : "Unwatched", downloaded ? "Downloaded" : nil].compactMap { $0 }
                        .joined(separator: ", ")
                )
                .accessibilityHint("Plays a downloaded copy when available or opens online sources")
            HStack(spacing: 8) {
                Button(action: play) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.caption)
                        Text(playbackLabel).font(.subheadline.weight(.medium))
                    }.frame(
                        minWidth: Design.minimumHitTarget, minHeight: Design.minimumHitTarget,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Play \(episode.displayTitle), \(playbackLabel)")
                Spacer(minLength: 4)
                Menu {
                    Button("Play episode", systemImage: "play", action: play)
                    if let chooseOnline {
                        Button("Choose Online Source", systemImage: "network", action: chooseOnline)
                    }
                    if let download { Button("Download", systemImage: "arrow.down.circle", action: download) }
                    if WatchProgress.supports(media), media.type == "series" {
                        Button(
                            watched ? "Mark as Unwatched" : "Mark as Watched",
                            systemImage: watched ? "circle" : "checkmark.circle"
                        ) {
                            store.setWatched(!watched, for: media, episode: episode)
                        }
                    }
                    if let overview = episode.overview, !overview.isEmpty {
                        Button("Episode description", systemImage: "text.alignleft", action: showDescription)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.bold))
                        .frame(width: Design.minimumHitTarget, height: Design.minimumHitTarget).contentShape(
                            Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Options for \(episode.displayTitle)")
            }.foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 12).padding(.bottom, 8)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                .white.opacity(0.16), lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            if watched { WatchedBadge().padding(10) }
        }
        .overlay(alignment: .topLeading) {
            if downloaded { DownloadedBadge().padding(10) }
        }
    }
}
