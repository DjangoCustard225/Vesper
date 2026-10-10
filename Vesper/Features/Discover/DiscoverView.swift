import SwiftUI
import VesperCore

struct DiscoverView: View {
    @Environment(AppStore.self) private var store
    @State private var heroOffset: CGFloat = 0
    private var feeds: [CatalogFeed] { store.feeds }

    var body: some View {
        let items = store.heroItems
        return ImmersiveScrollView(artworkURL: nil, headerHeight: items.isEmpty ? 0 : Design.heroHeight,
                                  artworkURLs: items.map { $0.background ?? $0.poster }, artworkOffset: heroOffset) {
            VStack(alignment: .leading, spacing: 24) {
                if !items.isEmpty { HeroCarousel(items: items, horizontalOffset: $heroOffset).id(store.heroCatalogID) }
                if store.isLoading && store.feeds.isEmpty && store.tmdbFeeds.isEmpty {
                    ProgressView("Finding your next watch…").frame(maxWidth: .infinity).padding(.vertical, 100)
                }
                if !store.continueWatching.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Continue watching").font(.title2.bold()).padding(.horizontal, 20)
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 14) {
                                ForEach(store.continueWatching.prefix(12)) { progress in
                                    NavigationLink { DetailView(item: progress.media, preferredVideoID: progress.videoID) } label: {
                                        ContinueCard(progress: progress)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { Button("Remove from continue watching", role: .destructive) { store.removeProgress(progress) } }
                                }
                            }.padding(.horizontal, 20)
                        }.scrollIndicators(.hidden).appScrollEdges()
                    }
                }
                if store.tmdbCredential == nil {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Discover with TMDB").font(.title2.bold())
                        Text("Add your TMDB key in Settings to browse movies, series, and cast portraits.").foregroundStyle(.secondary)
                        NavigationLink { TMDBSettingsView() } label: { Label("Connect TMDB", systemImage: "key").accentButtonForeground() }.buttonStyle(.glassProminent)
                    }.padding(24)
                }
                ForEach(store.tmdbFeeds) { feed in TMDBShelf(feed: feed) }
                ForEach(feeds) { feed in
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            NavigationLink { CatalogView(feed: feed) } label: {
                                CatalogHeading(title: feed.catalog.title)
                            }.buttonStyle(.plain).accessibilityLabel("See all \(feed.catalog.title)")
                            Text(feed.subtitle).font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 20)
                        if let error = feed.error {
                            ErrorNotice(message: error) { Task { await store.refresh() } }.padding(.horizontal, 20)
                        } else if feed.items.isEmpty {
                            if store.isLoading { ProgressView().padding(.horizontal, 20) }
                            else { Text("No titles in this catalog yet.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20) }
                        } else {
                            ScrollView(.horizontal) {
                                LazyHStack(alignment: .top, spacing: Design.posterSpacing) {
                                    ForEach(feed.items.prefix(20), id: \.key) { item in
                                        NavigationLink { DetailView(item: item) } label: { PosterCard(item: item, width: Design.posterWidth) }.buttonStyle(.plain)
                                    }
                                }.padding(.horizontal, 20)
                            }.scrollIndicators(.hidden).appScrollEdges()
                        }
                    }
                }
                if !store.isLoading && feeds.isEmpty && store.tmdbFeeds.isEmpty && store.tmdbCredential != nil {
                    ContentUnavailableView("Your next watch starts here", systemImage: "sparkles.tv", description: Text("Browse movies and series from TMDB."))
                }
            }.padding(.bottom, 20).frame(maxWidth: .infinity)
        }
        .ignoresSafeArea(.container, edges: items.isEmpty ? [] : .top)
        .appBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: store.heroCatalogID) { _, _ in heroOffset = 0 }
    }
}

struct FeaturedCard: View {
    @Environment(AppStore.self) private var store
    let item: MediaItem
    var presentation: HeroPresentation?
    private var media: MediaItem { presentation?.media ?? item }
    private var saved: Bool { store.contains(media) }
    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationLink { DetailView(item: media) } label: {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Details for \(media.name)")
            VStack(spacing: 20) {
                NavigationLink { DetailView(item: media) } label: {
                    PosterTitle(name: media.name, logoURL: nil, preparedImage: presentation?.titleImage,
                                isLoading: presentation == nil)
                }.buttonStyle(.plain).accessibilityLabel("Details for \(media.name)")
                HStack(spacing: 12) {
                    NavigationLink {
                        DetailView(item: media, preferredVideoID: store.continueWatching.first { $0.media.isSameTitle(as: media) }?.videoID, startPlayback: true)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline).padding(.horizontal, 30).frame(minHeight: 48)
                            .foregroundStyle(.black).background(.white, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("Play \(media.name)")
                    Button { store.toggleLibrary(media) } label: {
                        Image(systemName: saved ? "checkmark" : "plus")
                            .font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                            .foregroundStyle(.black).background(.white, in: Circle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(saved ? "Remove \(media.name) from library" : "Add \(media.name) to library")
                        .accessibilityValue(saved ? "Saved" : "Not saved")
                }
            }.padding(.horizontal, 24).padding(.bottom, 24)
        }
        .frame(height: Design.heroHeight)
    }
}

struct ContinueCard: View {
    let progress: WatchProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Color.clear.frame(height: 126)
                .overlay { Artwork(url: progress.media.background ?? progress.media.poster) }
                .overlay { Image(systemName: "play.circle.fill").font(.largeTitle).symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.5)) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottom) { ProgressView(value: progress.fraction).padding(.horizontal, 10).padding(.bottom, 8) }
        }.frame(width: 224).accessibilityElement(children: .ignore)
            .accessibilityLabel(progress.media.name)
            .accessibilityValue(progress.episodeTitle ?? "\(Int(progress.position / 60)) min watched")
    }
}
