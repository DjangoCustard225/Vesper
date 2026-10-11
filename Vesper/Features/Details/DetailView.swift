import SwiftUI
import VesperCore

struct DetailView: View {
    @Environment(AppStore.self) private var store
    let item: MediaItem
    var startPlayback = false
    @State private var didStartPlayback = false
    @State private var full: MediaItem?
    @State private var loading = false
    @State private var error: String?
    @State private var season: Int? = nil
    @State private var selection: VideoSelection?
    @State private var enrichment: TMDBEnrichment?
    @State private var enriching = false
    @State private var tmdbError: String?
    @State private var seasonLoading = false
    @State private var seasonError: String?
    @State private var seasonEpisodes: [Episode] = []
    @State private var seasonRequestID = UUID()
    @State private var showingAbout = false
    @State private var episodeAbout: Episode?
    @State private var summaryHeight: CGFloat = 140
    private var media: MediaItem { full ?? item }
    private var seasons: [Int] { enrichment?.seasons.isEmpty == false ? enrichment!.seasons : Array(Set((media.videos ?? []).compactMap(\.season))).sorted() }
    private var episodes: [Episode] {
        (enrichment?.mediaType == "tv" ? seasonEpisodes : media.videos ?? []).filter { season == nil || $0.season == season }.sorted {
            if $0.season != $1.season { return ($0.season ?? 0) < ($1.season ?? 0) }
            return ($0.episode ?? 0) < ($1.episode ?? 0)
        }
    }
    private var isLive: Bool { media.type == "tv" || media.behaviorHints?.isLive == true }

    var body: some View {
        ImmersiveScrollView(artworkURL: media.background ?? media.poster, headerHeight: 390 + 24 + summaryHeight + 90) {
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .bottom) {
                    Color.clear
                    VStack(spacing: 16) {
                        PosterTitle(name: media.name, logoURL: enrichment?.titleLogoURL)
                        if let rating = media.imdbRating {
                            Label(rating, systemImage: "star.fill").font(.subheadline).foregroundStyle(.tint)
                        }
                    }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.bottom, 20)
                }.frame(height: 390)

                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 24) {
                        titleActions
                        if let description = media.description, !description.isEmpty {
                            Button { showingAbout = true } label: {
                                Text(description).font(.body).foregroundStyle(.secondary)
                                    .lineSpacing(4).lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("About. \(description)")
                                .accessibilityHint("Opens the full description")
                                .padding(.horizontal, -4).padding(.top, -12)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { summaryHeight = $0 }
                    if loading { ProgressView("Loading details…").frame(maxWidth: .infinity) }
                    if let error { ErrorNotice(message: error) { Task { await load() } } }
                    if enriching { ProgressView("Loading details…").font(.subheadline).frame(maxWidth: .infinity) }
                    if let tmdbError { ErrorNotice(message: tmdbError) { Task { await enrich() } } }
                    if !isLive && (media.type == "series" || !(media.videos ?? []).isEmpty) { episodeSection }
                    if let enrichment { RelatedTitlesView(details: enrichment) }
                    if let cast = enrichment?.cast, !cast.isEmpty {
                        PeoplePortraitsView(people: cast, title: "Cast")
                    }
                    crewSection
                }.padding(.horizontal, 24).padding(.bottom, 32)
                    .frame(maxWidth: 1000).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity)
        }
            .ignoresSafeArea(.container, edges: .top)
            .appBackground().navigationBarTitleDisplayMode(.inline)
            .fontDesign(.default)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .task(id: item.key + store.tmdbRevision.uuidString) { await load() }
            .task(id: store.metadataRevision(for: [store.detailsCacheID(media)])) {
                guard enrichment != nil else { return }
                await enrich()
            }
            .task(id: "\(enrichment?.id ?? 0):\(season ?? -1):\(store.tmdbRevision):" + store.metadataRevision(for: [store.episodesCacheID(media, details: enrichment, season: season)])) {
                await loadSeason(preserveExisting: !seasonEpisodes.isEmpty)
            }
            .sheet(item: $selection) { video in StreamPickerView(media: media, video: video).presentationDragIndicator(.visible) }
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
                Button { store.toggleLibrary(media) } label: {
                    Label(store.contains(media) ? "In Library" : "Add to Library", systemImage: store.contains(media) ? "checkmark" : "plus")
                        .font(.headline).padding(.horizontal, 20).frame(minHeight: 48).accentButtonForeground()
                }.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    .accessibilityLabel(store.contains(media) ? "Remove from library" : "Add to library")
                    .accessibilityValue(store.contains(media) ? "Saved" : "Not saved")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } else {
            HStack(spacing: 12) {
                playButton
                Button { store.toggleLibrary(media) } label: {
                    Image(systemName: store.contains(media) ? "checkmark" : "plus")
                        .font(.title3.weight(.semibold)).frame(width: 48, height: 48).accentButtonForeground()
                }.buttonStyle(.glassProminent).buttonBorderShape(.circle)
                    .accessibilityLabel(store.contains(media) ? "Remove from library" : "Add to library")
                    .accessibilityValue(store.contains(media) ? "Saved" : "Not saved")
            }
        }
    }
    private var playButton: some View {
        Button { playDefault() } label: {
            Label("Play", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
                .accentButtonForeground()
        }.buttonStyle(.glassProminent).disabled(loading || enriching)
    }
    private func playDefault() {
        let rawID = media.behaviorHints?.defaultVideoId ?? media.playbackID
        let id = isLive ? media.id : MediaIdentity.videoID(rawID, for: media)
        let episode = media.videos?.first { $0.id == id }
        selection = VideoSelection(id: id, title: episode.map { $0.label + " · " + $0.displayTitle }, embedded: episode?.streams)
    }
    private func load() async {
        loading = true; enrichment = nil; enriching = false; tmdbError = nil; seasonEpisodes = []; seasonError = nil
        let (result, failure) = await store.metadata(for: item)
        guard !Task.isCancelled else { return }
        full = result; error = failure; loading = false
        if season == nil { season = seasons.first(where: { $0 > 0 }) ?? seasons.first }
        await enrich()
        startRequestedPlayback()
    }
    private func enrich() async {
        guard store.tmdbCredential != nil, media.type == "movie" || media.type == "series" else { return }
        let original = media
        enriching = true; tmdbError = nil
        do {
            let result = try await store.enrichedMetadata(for: original)
            guard !Task.isCancelled else { return }
            enrichment = result
            if let result {
                full = result.applying(to: original)
                if season == nil || !result.seasons.contains(season!) { season = result.seasons.first(where: { $0 > 0 }) ?? result.seasons.first }
            }
        } catch is CancellationError { return }
        catch { tmdbError = error.localizedDescription }
        enriching = false
        startRequestedPlayback()
    }
    private func loadSeason(preserveExisting: Bool = false) async {
        let request = UUID(); seasonRequestID = request
        if !preserveExisting { seasonEpisodes = [] }
        seasonError = nil; seasonLoading = false
        guard let enrichment, enrichment.mediaType == "tv", let season else { return }
        seasonLoading = true
        do {
            let videos = try await store.episodes(for: media, details: enrichment, season: season)
            guard !Task.isCancelled, seasonRequestID == request, self.season == season, self.enrichment?.id == enrichment.id else { return }
            seasonEpisodes = videos
            startRequestedPlayback()
        } catch is CancellationError { return }
        catch { if !Task.isCancelled && seasonRequestID == request { seasonError = error.localizedDescription } }
        if !Task.isCancelled && seasonRequestID == request { seasonLoading = false }
    }
    private func startRequestedPlayback() {
        guard startPlayback, !didStartPlayback, !loading, !enriching, error == nil, tmdbError == nil else { return }
        if media.type != "series" || isLive || media.behaviorHints?.defaultVideoId != nil {
            didStartPlayback = true
            playDefault()
        } else if let episode = episodes.first {
            didStartPlayback = true
            selection = VideoSelection(id: episode.id, title: episode.label + " · " + episode.displayTitle, embedded: episode.streams)
        }
    }
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !seasons.isEmpty {
                Menu {
                    Picker("Season", selection: $season) {
                        ForEach(seasons, id: \.self) { Text($0 == 0 ? "Specials" : "Season \($0)").tag(Optional($0)) }
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
            if episodes.isEmpty && !loading && !enriching && !seasonLoading && seasonError == nil { Text("No episodes available. Connect TMDB in Settings to load movie and series details.").foregroundStyle(.secondary).font(.subheadline) }
            if !episodes.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(episodes) { episode in
                            EpisodeCard(media: media, episode: episode, play: {
                                selection = VideoSelection(id: episode.id, title: episode.label + " · " + episode.displayTitle, embedded: episode.streams)
                            }, showDescription: { episodeAbout = episode })
                        }
                    }.scrollTargetLayout().padding(.horizontal, 20)
                }
                .scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden).appScrollEdges()
                .padding(.horizontal, -20).id(season)
            }
        }.padding(.horizontal, -4)
    }
}
