import SwiftUI
import VesperCore

struct DetailView: View {
    @Environment(AppStore.self) private var store
    let item: MediaItem
    @State private var model: DetailLoadingController
    @State private var selection: VideoSelection?
    @State private var showingAbout = false
    @State private var episodeAbout: Episode?
    @State private var summaryHeight: CGFloat = 140

    init(item: MediaItem, startPlayback: Bool = false) {
        self.item = item
        _model = State(initialValue: DetailLoadingController(item: item, startPlayback: startPlayback))
    }
    init(item: MediaItem, startPlayback: Bool = false, resumeRecord: WatchRecord?) {
        self.item = item
        _model = State(
            initialValue: DetailLoadingController(
                item: item, startPlayback: startPlayback, resumeRecord: resumeRecord))
    }

    private var media: MediaItem { model.media }

    private var seasons: [Int] { model.seasons }

    private var episodes: [Episode] { model.episodes }

    private var season: Int? { model.season }

    private var enrichment: MetadataEnrichment? { model.enrichment }

    private var loading: Bool { model.loading }

    private var error: String? { model.error }

    private var enriching: Bool { model.enriching }

    private var metadataError: String? { model.metadataError }

    private var seasonLoading: Bool { model.seasonLoading }

    private var seasonError: String? { model.seasonError }

    private var isLive: Bool { model.isLive }

    var body: some View {
        GeometryReader { viewport in
            let isLandscape = viewport.size.width > viewport.size.height
            let headerHeight = isLandscape ? Design.landscapeDetailHeight(for: viewport.size.height) : 390
            ImmersiveScrollView(
                artwork: ImmersiveArtworkSource(backdrop: media.background, poster: media.poster),
                headerHeight: isLandscape ? headerHeight : headerHeight + 24 + summaryHeight + 90,
                isLandscape: isLandscape
            ) {
                VStack(alignment: .leading, spacing: 24) {
                    ZStack(alignment: isLandscape ? .bottomLeading : .bottom) {
                        Color.clear
                        VStack(alignment: isLandscape ? .leading : .center, spacing: isLandscape ? 8 : 16) {
                            PosterTitle(
                                name: media.name, logoURL: enrichment?.titleLogoURL,
                                compact: isLandscape, alignment: isLandscape ? .leading : .center)
                            if let rating = media.imdbRating {
                                Label(rating, systemImage: "star.fill").font(.subheadline).foregroundStyle(
                                    .tint)
                            }
                            if isLandscape { titleActions }
                        }
                        .frame(
                            maxWidth: isLandscape ? 380 : .infinity,
                            alignment: isLandscape ? .leading : .center
                        )
                        .padding(.horizontal, isLandscape ? 40 : 24)
                        .padding(.bottom, isLandscape ? 20 : 20)
                    }.frame(height: headerHeight)

                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 24) {
                            if !isLandscape { titleActions }
                            if let description = media.description, !description.isEmpty {
                                Button {
                                    showingAbout = true
                                } label: {
                                    Text(description).font(.body).foregroundStyle(.secondary)
                                        .lineSpacing(4).lineLimit(2).truncationMode(.tail)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("About. \(description)")
                                    .accessibilityHint("Opens the full description")
                                    .padding(.horizontal, -4).padding(.top, isLandscape ? 0 : -12)
                                    .frame(maxWidth: 650, alignment: .leading)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            summaryHeight = $0
                        }
                        if loading { ProgressView("Loading details…").frame(maxWidth: .infinity) }
                        if let error { ErrorNotice(message: error) { Task { await load() } } }
                        if enriching {
                            ProgressView("Loading details…").font(.subheadline).frame(maxWidth: .infinity)
                        }
                        if let metadataError {
                            ErrorNotice(message: metadataError) { Task { await enrich() } }
                        }
                        if !isLive && (media.type == "series" || !(media.videos ?? []).isEmpty) {
                            episodeSection
                        }
                        if let enrichment, enrichment.tmdbID != nil, store.tmdbCredential != nil {
                            RelatedTitlesView(details: enrichment)
                        }
                        if let cast = enrichment?.cast, !cast.isEmpty {
                            PeoplePortraitsView(people: cast, title: "Cast")
                        }
                        crewSection
                    }.padding(.horizontal, 24).padding(.bottom, 32)
                        .frame(maxWidth: 1000).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .appBackground().navigationBarTitleDisplayMode(.inline)
        .fontDesign(.default)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: item.key + store.metadataConfigurationRevision) { await load() }
        .task(id: store.metadataRevision(for: [store.detailsCacheID(media)])) {
            guard enrichment != nil else { return }
            await enrich()
        }
        .task(
            id: "\(enrichment?.reference.key ?? ""):\(season ?? -1):\(store.metadataConfigurationRevision):"
                + store.metadataRevision(for: [
                    store.episodesCacheID(media, details: enrichment, season: season)
                ])
        ) {
            await loadSeason(preserveExisting: !model.seasonEpisodes.isEmpty)
        }
        .sheet(item: $selection) { video in
            StreamPickerView(media: media, video: video, episodes: episodes, details: enrichment)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingAbout) {
            AboutDescriptionView(title: media.name, description: media.description ?? "")
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(item: $episodeAbout) { episode in
            AboutDescriptionView(title: episode.displayTitle, description: episode.overview ?? "")
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder private var crewSection: some View {
        if let crew = enrichment?.crew, !crew.isEmpty {
            PeoplePortraitsView(crew: crew)
        }
    }

    @ViewBuilder private var titleActions: some View {
        if media.type == "series" && !isLive {
            VStack(spacing: 12) {
                if media.behaviorHints?.defaultVideoId != nil { playButton }
                Button {
                    store.toggleLibrary(media)
                } label: {
                    Label(
                        store.contains(media) ? "In Library" : "Add to Library",
                        systemImage: store.contains(media) ? "checkmark" : "plus"
                    )
                    .font(.headline).padding(.horizontal, 20).frame(minHeight: 48).accentButtonForeground()
                }.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    .accessibilityLabel(store.contains(media) ? "Remove from library" : "Add to library")
                    .accessibilityValue(store.contains(media) ? "Saved" : "Not saved")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            HStack(spacing: 12) {
                playButton
                Button {
                    store.toggleLibrary(media)
                } label: {
                    Image(systemName: store.contains(media) ? "checkmark" : "plus")
                        .font(.title3.weight(.semibold)).frame(width: 48, height: 48).accentButtonForeground()
                }.buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .accessibilityLabel(store.contains(media) ? "Remove from library" : "Add to library")
                    .accessibilityValue(store.contains(media) ? "Saved" : "Not saved")
            }
        }
    }

    private var playButton: some View {
        Button {
            playDefault()
        } label: {
            Label("Play", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(
                .vertical, 9
            )
            .accentButtonForeground()
        }.buttonStyle(.glassProminent).disabled(loading || enriching)
    }

    private func playDefault() {
        let choice = model.defaultPlayback()
        selection = VideoSelection(id: choice.id, title: choice.title, embedded: choice.embedded)
    }

    private func load() async {
        if store.hasMetadata(for: item) {
            await model.load(
                metadata: { await store.metadata(for: $0) },
                enrich: { try await store.enrichedMetadata(for: $0) })
        } else {
            await model.load(metadata: { await store.metadata(for: $0) })
        }
        if !Task.isCancelled, media.type == "series" {
            await store.refreshTraktWatchedEpisodes(for: media)
        }
        startRequestedPlayback()
    }

    private func enrich() async {
        guard store.hasMetadata(for: item) else { return }
        await model.refreshEnrichment { try await store.enrichedMetadata(for: $0) }
        startRequestedPlayback()
    }

    private func loadSeason(preserveExisting: Bool = false) async {
        await model.loadSeason(preserveExisting: preserveExisting) { media, details, season in
            try await store.episodes(for: media, details: details, season: season)
        }
        startRequestedPlayback()
    }

    private func startRequestedPlayback() {
        guard let choice = model.requestedPlayback() else { return }
        selection = VideoSelection(id: choice.id, title: choice.title, embedded: choice.embedded)
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !seasons.isEmpty {
                Menu {
                    Picker("Season", selection: Binding(get: { model.season }, set: { model.season = $0 })) {
                        ForEach(seasons, id: \.self) {
                            Text($0 == 0 ? "Specials" : "Season \($0)").tag(Optional($0))
                        }
                    }
                } label: {
                    HStack(spacing: 7) {
                        Text(season.map { $0 == 0 ? "Specials" : "Season \($0)" } ?? "Season")
                            .font(.title2.bold()).foregroundStyle(.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.title3.weight(.bold)).foregroundStyle(.gray)
                    }.padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Choose a season")
            } else {
                Text("Episodes").font(.title2.bold())
            }
            if seasonLoading { ProgressView("Loading episodes…").frame(maxWidth: .infinity) }
            if let seasonError { ErrorNotice(message: seasonError) { Task { await loadSeason() } } }
            if episodes.isEmpty && !loading && !enriching && !seasonLoading && seasonError == nil {
                Text("No episodes available. Connect TMDB or TVDB in Settings to load show details.")
                    .foregroundStyle(.secondary).font(.subheadline)
            }
            if !episodes.isEmpty {
                EpisodeShelf(
                    media: media, episodes: episodes,
                    play: { selection = VideoSelection(episode: $0) },
                    showDescription: { episodeAbout = $0 }
                )
                .padding(.horizontal, -20).id(season)
            }
        }.padding(.horizontal, -4)
    }
}
