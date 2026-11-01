import SwiftUI
import VesperCore

struct DetailView: View {
    @Environment(AppStore.self) private var store
    let item: MediaItem
    @State private var model: DetailLoadingController
    @State private var router = DownloadPlaybackRouter()
    @State private var didRouteInitialDownload = false
    private let startPlayback: Bool
    private let resumeRecord: WatchRecord?
    private struct SourceSelection: Identifiable {
        let id = UUID()
        let video: VideoSelection
        let intent: StreamPickerIntent
    }
    @State private var selection: SourceSelection?
    @State private var preparingEpisode = true
    @State private var episodeAbout: Episode?

    init(item: MediaItem, startPlayback: Bool = false) {
        self.item = item
        self.startPlayback = startPlayback
        self.resumeRecord = nil
        _model = State(initialValue: DetailLoadingController(item: item, startPlayback: startPlayback))
    }
    init(item: MediaItem, startPlayback: Bool = false, resumeRecord: WatchRecord?) {
        self.item = item
        self.startPlayback = startPlayback
        self.resumeRecord = resumeRecord
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
        ContentDetailLayout(media: displayMedia, logoURL: enrichment?.titleLogoURL) {
            playButton
        } content: {
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
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 0) {
                    Button {
                        store.toggleLibrary(media)
                    } label: {
                        Image(systemName: store.contains(media) ? "checkmark" : "plus")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(store.contains(media) ? "Remove from library" : "Add to library")
                    Rectangle().fill(.primary.opacity(0.25)).frame(width: 1, height: 22)
                    Button {
                        guard let choice = model.defaultPlayback() else { return }
                        openSources(
                            VideoSelection(
                                id: choice.id, title: choice.title, embedded: choice.embedded,
                                episode: choice.episode), intent: .download)
                    } label: {
                        Image(systemName: "arrow.down")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(
                        !store.downloads.networkAvailable || isLive || loading || enriching
                            || preparingEpisode || model.defaultPlayback() == nil
                    )
                    .accessibilityLabel("Download")
                }
                .font(.headline).foregroundStyle(.primary).buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: true)
            }
        }
        .downloadedPlayback(router, knownEpisodes: episodes)
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
        .sheet(item: $selection) { selection in
            StreamPickerView(
                media: media, video: selection.video, episodes: episodes, details: enrichment,
                intent: selection.intent
            )
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $episodeAbout) { episode in
            AboutDescriptionView(title: episode.displayTitle, description: episode.overview ?? "")
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    private var hasLocalMovie: Bool {
        media.type == "movie"
            && !store.downloads.candidates(
                media: media, video: VideoSelection(id: media.playbackID, title: nil, embedded: nil)
            ).isEmpty
    }
    private var displayMedia: MediaItem {
        guard !store.downloads.networkAvailable,
            let saved = store.downloads.completed.first(where: { $0.media.isSameTitle(as: media) })
        else { return media }
        return store.downloads.offlineMedia(saved)
    }
    private func route(_ video: VideoSelection) {
        router.route(media: media, video: video, store: store, knownEpisodes: episodes) {
            openSources(video, intent: .playback)
        }
    }
    private func openSources(_ video: VideoSelection, intent: StreamPickerIntent) {
        selection = SourceSelection(video: video, intent: intent)
    }
    @ViewBuilder private var crewSection: some View {
        if let crew = enrichment?.crew, !crew.isEmpty {
            PeoplePortraitsView(crew: crew)
        }
    }

    private var playButton: some View {
        Button {
            playDefault()
        } label: {
            Label("Play", systemImage: "play.fill").font(.headline)
                .frame(maxWidth: .infinity).frame(height: 40).foregroundStyle(.primary)
        }
        .frame(maxWidth: 280).frame(maxWidth: .infinity, alignment: .center)
        .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).disabled(
            !hasLocalMovie && (loading || enriching || preparingEpisode || model.defaultPlayback() == nil))
    }

    private func playDefault() {
        if hasLocalMovie {
            route(VideoSelection(id: media.playbackID, title: nil, embedded: nil))
        } else if let choice = model.defaultPlayback() {
            route(
                VideoSelection(
                    id: choice.id, title: choice.title, embedded: choice.embedded, episode: choice.episode))
        }
    }

    private func load() async {
        let canRefreshEarly =
            item.type == "series"
            && (MediaIdentity.validIMDb(item.id) != nil
                || (item.id.hasPrefix("tmdb:") && MediaIdentity.tmdbID(item) != nil)
                || (item.id.hasPrefix("trakt:") && Int(item.id.dropFirst(6)).map { $0 > 0 } == true))
        async let downloadsReady: Void = store.downloads.ready()
        async let watchedRefresh: Void = {
            if canRefreshEarly { await store.refreshTraktWatchedEpisodes(for: item) }
        }()
        if startPlayback, !didRouteInitialDownload {
            await downloadsReady
            guard !Task.isCancelled else { return }
            let video = VideoSelection(
                id: resumeRecord?.playbackID(for: item) ?? item.playbackID,
                title: resumeRecord?.subtitle, embedded: nil)
            if !store.downloads.candidates(media: item, video: video).isEmpty {
                didRouteInitialDownload = true; route(video)
            }
        }
        preparingEpisode = true
        if store.hasMetadata(for: item) {
            await model.load(
                metadata: { await store.metadata(for: $0) },
                enrich: { try await store.enrichedMetadata(for: $0) })
        } else {
            await model.load(metadata: { await store.metadata(for: $0) })
        }
        if !Task.isCancelled, media.type == "series" {
            if canRefreshEarly {
                await watchedRefresh
            } else {
                await store.refreshTraktWatchedEpisodes(for: media)
            }
            guard !Task.isCancelled else { return }
            await prepareInitialEpisode()
        }
        await downloadsReady
        guard !Task.isCancelled else { return }
        preparingEpisode = false
        startRequestedPlayback()
    }

    private func prepareInitialEpisode() async {
        preparingEpisode = true
        await model.selectInitialEpisode(history: store.watchProgress) { media, details, season in
            if let details { return try await store.episodes(for: media, details: details, season: season) }
            return (media.videos ?? []).filter { $0.season == season }
        }
        guard !Task.isCancelled else { return }
        preparingEpisode = false
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
        guard !preparingEpisode, !didRouteInitialDownload, let choice = model.requestedPlayback() else {
            return
        }
        route(
            VideoSelection(
                id: choice.id, title: choice.title, embedded: choice.embedded, episode: choice.episode))
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !seasons.isEmpty {
                EpisodeSeasonPicker(
                    seasons: seasons, season: Binding(get: { model.season }, set: { model.selectSeason($0) }))
            } else {
                Text("Episodes").font(.title2.bold())
            }
            if let failure = model.initialEpisodeError {
                ErrorNotice(message: failure) { Task { await prepareInitialEpisode() } }
            }
            if seasonLoading { ProgressView("Loading episodes…").frame(maxWidth: .infinity) }
            if let seasonError { ErrorNotice(message: seasonError) { Task { await loadSeason() } } }
            if episodes.isEmpty && !loading && !enriching && !seasonLoading && seasonError == nil {
                Text("No episodes available. Connect TMDB or TVDB in Settings to load show details.")
                    .foregroundStyle(.secondary).font(.subheadline)
            }
            if !episodes.isEmpty {
                EpisodeShelf(
                    media: media, episodes: episodes, initialEpisodeID: model.initialEpisode?.id,
                    play: { route(VideoSelection(episode: $0)) },
                    chooseOnline: { openSources(VideoSelection(episode: $0), intent: .playback) },
                    download: { openSources(VideoSelection(episode: $0), intent: .download) },
                    showDescription: { episodeAbout = $0 }
                )
                .padding(.horizontal, -20).id(season)
            }
        }.padding(.horizontal, -4)
    }
}
