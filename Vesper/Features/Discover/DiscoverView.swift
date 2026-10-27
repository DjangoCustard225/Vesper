import SwiftUI
import VesperCore

struct DiscoverView: View {
    @Environment(AppStore.self) private var store
    @State private var heroPage: CGFloat = 0
    @State private var heroArtwork: [String: ImmersiveArtworkSource] = [:]

    var body: some View {
        let items = store.heroItems
        let continuing = store.showContinueWatching ? store.watchProgress.continueWatching : []
        return GeometryReader { viewport in
            let isLandscape = viewport.size.width > viewport.size.height
            let heroHeight =
                isLandscape ? Design.landscapeHeroHeight(for: viewport.size.height) : Design.heroHeight
            ImmersiveScrollView(
                artwork: ImmersiveArtworkSource(backdrop: nil, poster: nil),
                headerHeight: items.isEmpty ? 0 : heroHeight,
                artworks: items.map {
                    heroArtwork[$0.key] ?? ImmersiveArtworkSource(backdrop: $0.background, poster: $0.poster)
                },
                artworkPage: heroPage, isLandscape: isLandscape
            ) {
                VStack(alignment: .leading, spacing: 24) {
                    if !items.isEmpty {
                        HeroCarousel(
                            items: items, height: heroHeight, isLandscape: isLandscape,
                            horizontalPage: $heroPage, artworkSources: $heroArtwork
                        )
                        .id(store.heroCatalogID)
                    }
                    if !continuing.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Continue Watching").font(.title2.bold()).padding(.horizontal, 20)
                            ContinueWatchingShelf(records: continuing)
                        }
                    }
                    HomeUpNext()
                    HomeCatalogSections(width: viewport.size.width)
                }.padding(.bottom, 20).frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: items.isEmpty ? [] : .top)
        .appBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: store.heroCatalogID) { _, _ in
            heroPage = 0
            heroArtwork = [:]
        }
        .onChange(of: store.metadataConfigurationRevision) { _, _ in heroArtwork = [:] }
    }
}

private struct HomeCatalogSections: View {
    @Environment(AppStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    let width: CGFloat
    @State private var prefetch = ArtworkPrefetchState()

    private var feeds: [CatalogFeed] { store.feeds }
    private var rows: [ArtworkPrefetchWindow.Row] {
        store.tmdbFeeds.map { .init(id: "tmdb:" + $0.id, items: $0.items) }
            + feeds.map { .init(id: "addon:" + $0.id, items: Array($0.items.prefix(20))) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            if store.isLoading && store.feeds.isEmpty && store.tmdbFeeds.isEmpty {
                ProgressView("Finding your next watch…").frame(maxWidth: .infinity).padding(
                    .vertical, 100)
            }
            if store.tmdbCredential == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Discover with TMDB").font(.title2.bold())
                    Text(
                        "Add your TMDB key in Settings to browse movies, series, and cast portraits."
                    ).foregroundStyle(.secondary)
                    NavigationLink {
                        TMDBSettingsView()
                    } label: {
                        Label("Connect TMDB", systemImage: "key").accentButtonForeground()
                    }.buttonStyle(.glassProminent)
                }.padding(24)
            }
            ForEach(store.tmdbFeeds) { feed in
                TMDBShelf(feed: feed)
                    .onScrollVisibilityChange(threshold: 0.01) { active in
                        prefetch.visibility(active, id: "tmdb:" + feed.id, rows: rows)
                    }
            }
            ForEach(feeds) { feed in
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        NavigationLink {
                            CatalogView(feed: feed)
                        } label: {
                            CatalogHeading(title: feed.catalog.title)
                        }.buttonStyle(.plain).accessibilityLabel("See all \(feed.catalog.title)")
                        Text(feed.subtitle).font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 20)
                    if let error = feed.error {
                        ErrorNotice(message: error) { Task { await store.refresh() } }.padding(
                            .horizontal, 20)
                    }
                    if feed.items.isEmpty && feed.error == nil {
                        if store.isLoading {
                            ProgressView().padding(.horizontal, 20)
                        } else {
                            Text("No titles in this catalog yet.").font(.subheadline).foregroundStyle(
                                .secondary
                            ).padding(.horizontal, 20)
                        }
                    } else if !feed.items.isEmpty {
                        PosterShelf(items: Array(feed.items.prefix(20)))
                    }
                }
                .onScrollVisibilityChange(threshold: 0.01) { active in
                    prefetch.visibility(active, id: "addon:" + feed.id, rows: rows)
                }
            }
            if !store.isLoading && feeds.isEmpty && store.tmdbFeeds.isEmpty
                && store.tmdbCredential != nil
            {
                ContentUnavailableView(
                    "Your next watch starts here", systemImage: "sparkles.tv",
                    description: Text("Browse movies and series from TMDB."))
            }
        }
        .prefetchArtwork(
            prefetch.urls(rows: rows, width: width),
            size: ArtworkDecodeSize(
                width: Design.posterWidth, height: Design.posterWidth * 1.5, scale: displayScale)
        )
        .onDisappear { prefetch.reset() }
    }
}

struct FeaturedCard: View {
    @Environment(AppStore.self) private var store
    let item: MediaItem
    var presentation: HeroPresentation?
    let height: CGFloat
    let isLandscape: Bool
    var showsPageControl = false

    private var media: MediaItem { presentation?.media ?? item }

    private var saved: Bool { store.contains(media) }

    private var bottomPadding: CGFloat {
        let standard: CGFloat = isLandscape ? 36 : 24
        return showsPageControl ? max(standard, Design.minimumHitTarget + 12) : standard
    }

    var body: some View {
        ZStack(alignment: isLandscape ? .bottomLeading : .bottom) {
            NavigationLink {
                DetailView(item: media)
            } label: {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Details for \(media.name)")
            VStack(alignment: isLandscape ? .leading : .center, spacing: isLandscape ? 12 : 20) {
                NavigationLink {
                    DetailView(item: media)
                } label: {
                    PosterTitle(
                        name: media.name, logoURL: nil, preparedImage: presentation?.titleImage,
                        isLoading: presentation == nil, compact: isLandscape,
                        alignment: isLandscape ? .leading : .center)
                }.buttonStyle(.plain).accessibilityLabel("Details for \(media.name)")
                HStack(spacing: 12) {
                    NavigationLink {
                        DetailView(item: media, startPlayback: true)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline).padding(.horizontal, 30).frame(minHeight: 48)
                            .foregroundStyle(.black).background(.white, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("Play \(media.name)")
                    Button {
                        store.toggleLibrary(media)
                    } label: {
                        Image(systemName: saved ? "checkmark" : "plus")
                            .font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                            .foregroundStyle(.black).background(.white, in: Circle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(
                            saved ? "Remove \(media.name) from library" : "Add \(media.name) to library"
                        )
                        .accessibilityValue(saved ? "Saved" : "Not saved")
                }
            }
            .frame(maxWidth: isLandscape ? 380 : .infinity, alignment: isLandscape ? .leading : .center)
            .padding(.horizontal, isLandscape ? 40 : 24).padding(.bottom, bottomPadding)
        }
        .frame(height: height)
        .modifier(MediaContextMenu(item: media))
    }
}
