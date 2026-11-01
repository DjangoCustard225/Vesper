import SwiftUI
import VesperCore

struct DiscoverView: View {
    @Environment(AppStore.self) private var store
    @State private var heroPage: CGFloat = 0

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
                    ImmersiveArtworkSource(
                        backdrop: $0.background, poster: $0.poster, prefersPoster: $0.type == "series")
                },
                artworkPage: heroPage, isLandscape: isLandscape
            ) {
                VStack(alignment: .leading, spacing: 24) {
                    if !items.isEmpty {
                        HeroCarousel(
                            items: items, height: heroHeight, isLandscape: isLandscape,
                            horizontalPage: $heroPage
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
        }
    }
}

private struct HomeCatalogSections: View {
    @Environment(AppStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    let width: CGFloat
    @State private var prefetch = ArtworkPrefetchState()

    var body: some View {
        let presentation = store.catalogPresentation
        let catalogs = presentation.rows
        let rows = presentation.prefetchRows
        return LazyVStack(alignment: .leading, spacing: 24) {
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
            ForEach(catalogs) { row in
                HomeCatalogShelf(row: row)
                    .onScrollVisibilityChange(threshold: 0.01) { active in
                        prefetch.visibility(active, id: row.id, rows: rows)
                    }
            }
            if catalogs.isEmpty, store.tmdbCredential != nil {
                ContentUnavailableView {
                    Label("No visible catalogs", systemImage: "rectangle.stack")
                } actions: {
                    NavigationLink("Manage Catalogs") { CatalogSettingsView() }
                }
            }
        }
        .modifier(HomeCatalogPrefetch(prefetch: prefetch, rows: rows, width: width, scale: displayScale))
        .onDisappear { prefetch.reset() }
    }
}

/// Visibility changes invalidate this modifier, leaving the catalog hierarchy alone.
private struct HomeCatalogPrefetch: ViewModifier {
    let prefetch: ArtworkPrefetchState
    let rows: [ArtworkPrefetchWindow.Row]
    let width: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.prefetchArtwork(
            prefetch.urls(rows: rows, width: width),
            size: ArtworkDecodeSize(
                width: Design.posterWidth, height: Design.posterWidth * 1.5, scale: scale))
    }
}

private struct HomeCatalogShelf: View {
    @Environment(AppStore.self) private var store
    let row: HomeCatalogRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                switch row.catalog {
                case .addon(let feed): CatalogView(feed: feed)
                case .tmdb(let catalog): TMDBCatalogView(catalog: catalog)
                case .combined(let group): CombinedCatalogView(group: group)
                }
            } label: {
                CatalogHeading(title: row.title)
            }.buttonStyle(.plain).accessibilityLabel("See all \(row.title)").padding(.horizontal, 20)
            if let error = row.error {
                ErrorNotice(message: error) { Task { await store.refresh() } }.padding(.horizontal, 20)
            }
            if row.items.isEmpty, row.error == nil {
                if row.isLoading {
                    ProgressView().padding(.horizontal, 20)
                } else if case .combined(let group) = row.catalog,
                    row.isUnavailable
                {
                    NavigationLink("Edit Catalog") { CombinedCatalogEditor(group: group) }
                        .padding(.horizontal, 20)
                } else {
                    Text("No titles in this catalog yet.").font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
            } else if !row.items.isEmpty {
                PosterShelf(items: row.items)
            }
        }
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

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationLink {
                DetailView(item: media)
            } label: {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Details for \(media.name)")
            VStack(spacing: 20) {
                NavigationLink {
                    DetailView(item: media)
                } label: {
                    PosterTitle(
                        name: media.name, logoURL: nil, preparedImage: presentation?.titleImage,
                        isLoading: presentation == nil)
                }.buttonStyle(.plain).accessibilityLabel("Details for \(media.name)")
                HStack(spacing: 12) {
                    NavigationLink {
                        DetailView(item: media, startPlayback: true)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline).padding(.horizontal, 30).frame(minHeight: 48)
                            .foregroundStyle(.white)
                    }.buttonStyle(.glass).buttonBorderShape(.capsule)
                        .accessibilityLabel("Play \(media.name)")
                    Button {
                        store.toggleLibrary(media)
                    } label: {
                        Image(systemName: saved ? "checkmark" : "plus")
                            .font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                            .foregroundStyle(.white)
                    }.buttonStyle(.glass).buttonBorderShape(.circle)
                        .accessibilityLabel(
                            saved ? "Remove \(media.name) from library" : "Add \(media.name) to library"
                        )
                        .accessibilityValue(saved ? "Saved" : "Not saved")
                }
            }.padding(.horizontal, 24).padding(.bottom, 48)
        }
        .frame(height: height)
        .modifier(MediaContextMenu(item: media))
    }
}
