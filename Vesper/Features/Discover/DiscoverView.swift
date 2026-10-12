import SwiftUI
import VesperCore

struct DiscoverView: View {
    @Environment(AppStore.self) private var store
    @State private var heroOffset: CGFloat = 0
    private var feeds: [CatalogFeed] { store.feeds }

    var body: some View {
        let items = store.heroItems
        let continuing = store.showContinueWatching ? store.watchProgress.continueWatching : []
        return ImmersiveScrollView(artworkURL: nil, headerHeight: items.isEmpty ? 0 : Design.heroHeight,
                                  artworkURLs: items.map { $0.background ?? $0.poster }, artworkOffset: heroOffset) {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !items.isEmpty { HeroCarousel(items: items, horizontalOffset: $heroOffset).id(store.heroCatalogID) }
                if !continuing.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Continue Watching").font(.title2.bold()).padding(.horizontal, 20)
                        ContinueWatchingShelf(records: continuing)
                    }
                }
                if store.isLoading && store.feeds.isEmpty && store.tmdbFeeds.isEmpty {
                    ProgressView("Finding your next watch…").frame(maxWidth: .infinity).padding(.vertical, 100)
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
                        }
                        if feed.items.isEmpty && feed.error == nil {
                            if store.isLoading { ProgressView().padding(.horizontal, 20) }
                            else { Text("No titles in this catalog yet.").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20) }
                        } else if !feed.items.isEmpty {
                            PosterShelf(items: Array(feed.items.prefix(20)))
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
                        DetailView(item: media, startPlayback: true)
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
        .modifier(MediaContextMenu(item: media))
    }
}
