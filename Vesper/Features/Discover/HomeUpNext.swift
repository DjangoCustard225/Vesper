import SwiftUI
import VesperCore

struct HomeUpNext: View {
    @Environment(AppStore.self) private var store
    @State private var feed = UpNextFeedController()
    @State private var selection: Selection?
    private struct Request: Equatable {
        let seeds: [UpNext.Seed]
        let metadata: String
        let addons: UUID
    }

    private struct Selection: Identifiable {
        let media: MediaItem
        let episode: Episode
        var id: String { media.key + ":" + episode.id }
    }

    var body: some View {
        let request = Request(
            seeds: UpNext.homeSeeds(in: store.watchProgress),
            metadata: store.metadataConfigurationRevision, addons: store.addonRevision)
        VStack(alignment: .leading, spacing: 12) {
            if !feed.items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Up Next").font(.title2.bold()).padding(.horizontal, 20)
                    UpNextShelf(items: feed.items) { item in
                        selection = Selection(media: item.media, episode: item.episode)
                    }
                }
            }
        }
        .task(id: request) {
            await feed.load(request.seeds, context: request.metadata + request.addons.uuidString) { seed in
                let (metadata, _) = await store.metadata(for: seed.media)
                let details =
                    store.hasMetadata(for: metadata)
                    ? try await store.enrichedMetadata(for: metadata) : nil
                let media = details?.applying(to: metadata) ?? metadata
                guard
                    let episode = try await store.nextEpisode(
                        for: media, after: seed.episode, knownEpisodes: media.videos ?? [], details: details)
                else { return nil }
                return UpNextFeedController.Item(media: media, episode: episode)
            }
        }
        .onDisappear { feed.cancel() }
        .sheet(item: $selection) { item in
            StreamPickerView(media: item.media, video: VideoSelection(episode: item.episode))
                .presentationDragIndicator(.visible)
        }
    }
}

private struct UpNextShelf: View {
    let items: [UpNextFeedController.Item]
    let play: (UpNextFeedController.Item) -> Void
    @State private var prefetch = ArtworkPrefetchState()
    @State private var visible = false

    private var artworkItems: [MediaItem] {
        items.map {
            var media = $0.media
            media.poster = media.background ?? media.poster
            return media
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                ForEach(items) { item in
                    UpNextCard(item: item, play: { play(item) })
                        .onScrollVisibilityChange(threshold: 0.01) { active in
                            prefetch.visibility(active, key: item.media.key, items: artworkItems)
                        }
                }
            }.padding(.horizontal, 20)
        }.scrollIndicators(.hidden).appScrollEdges()
            .onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
            .prefetchArtwork(visible ? prefetch.urls(artworkItems) : [])
            .onDisappear {
                visible = false
                prefetch.reset()
            }
    }
}

private struct UpNextCard: View {
    @Environment(AppStore.self) private var store
    let item: UpNextFeedController.Item
    let play: () -> Void
    @State private var showingDescription = false

    var body: some View {
        Button(action: play) {
            HomePlaybackCard(item: item.media, subtitle: item.episode.label)
        }.buttonStyle(.plain)
            .accessibilityLabel("Play \(item.media.name), \(item.episode.label)")
            .contextMenu { options }
            .overlay(alignment: .bottomTrailing) {
                Menu {
                    options
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8)).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.trailing, 6).padding(.bottom, 1)
                    .accessibilityLabel("Options for \(item.media.name)")
            }
            .sheet(isPresented: $showingDescription) {
                AboutDescriptionView(
                    title: item.episode.displayTitle, description: item.episode.overview ?? ""
                )
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
    }

    @ViewBuilder private var options: some View {
        Button("Play episode", systemImage: "play", action: play)
        if let overview = item.episode.overview,
            !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            Button("Episode description", systemImage: "text.alignleft") { showingDescription = true }
        }
        NavigationLink {
            DetailView(item: item.media)
        } label: {
            Label("View Details", systemImage: "info.circle")
        }
        Button("Mark Episode as Watched", systemImage: "checkmark.circle") {
            store.setWatched(true, for: item.media, episode: item.episode)
        }
        Button(
            store.contains(item.media) ? "Remove from Library" : "Add to Library",
            systemImage: store.contains(item.media) ? "checkmark" : "plus"
        ) {
            store.toggleLibrary(item.media)
        }
    }
}
