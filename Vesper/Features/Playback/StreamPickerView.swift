import SwiftUI
import VesperCore
import UsenetEngine

enum StreamPickerIntent { case playback, download }

struct StreamPickerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let media: MediaItem
    let intent: StreamPickerIntent
    @State private var video: VideoSelection
    @State private var model = StreamLoadingController()

    @State private var indexer = NZBFinderSearchController()
    @State private var packs = NZBFinderSearchController()
    private var nzbfinder: NZBFinderService { .shared }
    private var result: StreamResults {
        StreamResults(
            options: model.result.options + indexerReleases.map(\.streamOption),
            failures: model.result.failures)
    }
    private var indexerReleases: [NZBRelease] {
        var seen = Set<String>()
        return (indexer.releases + packs.releases).filter { seen.insert($0.id).inserted }
    }
    private var loading: Bool { model.loading || indexer.loading || packs.loading }
    private var episodeTarget: UsenetEpisodeTarget? {
        guard let episode = video.episode, let season = episode.season, let number = episode.episode else {
            return nil
        }
        return UsenetEpisodeTarget(
            season: season, episode: number, airDate: episode.released.map { String($0.prefix(10)) })
    }
    @State private var error: String?
    @State private var fullName: SourceName?
    private struct SourceName: Identifiable {
        let id = UUID()
        let value: String
    }
    @State private var launchTask: Task<Void, Never>?
    @State private var launching = false
    @State private var launchingUsenet = false
    @State private var playbackRequest: PlaybackRequest?
    @State private var playbackOption: StreamOption?
    @State private var downloadRouter = DownloadPlaybackRouter()
    @State private var usenet = UsenetPlaybackCoordinator()
    private enum PlaybackHandoff {
        case player(VideoPlayer)
        case episode(Episode)
    }
    @State private var pendingHandoff: PlaybackHandoff?
    private let episodes: [Episode]
    private let details: MetadataEnrichment?

    init(
        media: MediaItem, video: VideoSelection, episodes: [Episode] = [], details: MetadataEnrichment? = nil,
        intent: StreamPickerIntent = .playback
    ) {
        self.media = media
        self.intent = intent
        _video = State(initialValue: video)
        self.episodes = episodes
        self.details = details
    }

    var body: some View {
        NavigationStack {
            sources.navigationTitle(intent == .download ? "Choose a download" : "Choose a stream")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task(id: video.id + store.addonRevision.uuidString) { await load() }
                .task(id: video.id + nzbfinder.revision.uuidString) { await loadNZBFinder() }
                .onChange(of: store.addonRevision) { _, _ in launchTask?.cancel() }
                .onDisappear {
                    model.cancel()
                    indexer.cancel(); packs.cancel()
                    launchTask?.cancel()
                }
                .background {
                    BuiltInPlayerPresentation(
                        request: $playbackRequest, gesturePreferences: store.playerGestures,
                        players: store.availablePlayers,
                        onDismiss: finishPlayback
                    ) { player in
                        pendingHandoff = .player(player)
                        playbackRequest = nil
                    }
                }
                .alert(
                    intent == .download ? "Unable to download" : "Unable to play",
                    isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
                ) {
                    Button("OK") { error = nil }
                } message: {
                    Text(error ?? "")
                }
        }
        .overlay {
            if launchingUsenet || usenet.preparing {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 18) {
                        ProgressView("Preparing stream…")
                        Button("Cancel") {
                            launchingUsenet = false
                            launchTask?.cancel()
                            usenet.cancel()
                        }.buttonStyle(.glass)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                }
                .accessibilityAddTraits(.isModal)
            }
        }
        .downloadedPlayback(downloadRouter, knownEpisodes: episodes)
        .usenetPlayback(usenet, showsErrorAlert: false, onDismiss: finishPlayback)
        .sheet(item: $fullName) { name in
            ScrollView {
                Text(name.value).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(24)
            }.appScrollEdges().presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
    }

    private var sources: some View {
        @Bindable var store = store
        return SourceResultsScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(media.name).font(.title3.bold())
                if let title = video.title { Text(title).font(.subheadline).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            if intent == .playback {
                HStack {
                    Text("Player").font(.headline)
                    Spacer()
                    Picker("Player", selection: $store.preferredPlayer) {
                        ForEach(store.availablePlayers) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).labelsHidden()
                }.padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 22))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    }
            }
            if let error = usenet.error { ErrorNotice(message: error) }
            if model.loading {
                ProgressView("Finding streams…").frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            if indexer.loading || packs.loading {
                ProgressView("Searching NZBFinder…").frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            if let error = indexer.error ?? packs.error {
                ErrorNotice(message: "NZBFinder: " + error)
                Button("Retry NZBFinder") {
                    Task {
                        if indexer.error != nil, indexer.next != nil {
                            await indexer.loadNext()
                        } else if packs.error != nil, packs.next != nil {
                            await packs.loadNext()
                        } else {
                            await loadNZBFinder(refresh: true)
                        }
                    }
                }.buttonStyle(.glass)
            }
            if indexer.hasSearched, !indexer.loading, !packs.loading, indexerReleases.isEmpty,
                indexer.error == nil, packs.error == nil
            {
                Text("NZBFinder found no matching releases.").font(.subheadline).foregroundStyle(.secondary)
            }
            if !loading && options.isEmpty && indexer.error == nil && packs.error == nil
                && result.failures.isEmpty
                && usenet.error == nil
            {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        intent == .download ? "No downloadable sources" : "No streams found",
                        systemImage: "play.slash",
                        description: Text(
                            nzbfinder.enabled
                                ? "No matching releases were returned for this movie or episode."
                                : "Install a stream add-on or enable NZBFinder in Settings → Usenet."
                        ))
                    Button("Try again") {
                        Task {
                            async let addons: Void = load()
                            async let nzb: Void = loadNZBFinder(refresh: true)
                            _ = await (addons, nzb)
                        }
                    }.buttonStyle(.glass).frame(
                        maxWidth: .infinity)
                }
            }
            if !options.isEmpty {
                Text("Available sources").font(.headline).padding(.horizontal, 2).padding(.top, 12).padding(
                    .bottom, 4)
                ForEach(options) { option in
                    SourceResultCard(
                        option: option,
                        action: { if intent == .download { download(option) } else { play(option) } },
                        isDownloadMode: intent == .download,
                        isInDownloads: store.downloads.records.contains {
                            $0.media.isSameTitle(as: media) && $0.videoID == video.id
                                && StreamPolicy.refreshedMatch(for: $0.source, in: [option.source]) != nil
                        }
                    )
                    .disabled(launching)
                    .contextMenu {
                        Button("Show Full Name", systemImage: "text.alignleft") {
                            fullName = SourceName(value: option.displayName)
                        }
                        if downloadable(option) {
                            Button("Download", systemImage: "arrow.down.circle") { download(option) }
                        }
                        if intent == .playback {
                            ForEach(
                                store.availablePlayers.filter { option.source.nzbUrl == nil || $0.isInternal }
                            ) { player in
                                Button("Play in \(player.title)", systemImage: "play") {
                                    play(option, player: player)
                                }
                            }
                        }
                    }
                    .modifier(SourceCardScrollEffect())
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        if visible, let release = option.nzbRelease {
                            if release.id == indexer.releases.last?.id { Task { await indexer.loadNext() } }
                            if release.id == packs.releases.last?.id { Task { await packs.loadNext() } }
                        }
                    }
                }
            }
            if !result.failures.isEmpty {
                Text("Unavailable add-ons").font(.headline).padding(.top, 12)
                ForEach(result.failures, id: \.self) { failure in
                    ErrorNotice(message: failure)
                }
                Button("Retry add-ons") { Task { await load() } }.buttonStyle(.glass)
            }
        }
        // A new episode owns a new source-list offset and scroll-effect state.
        // Keep the player presenter outside this identity so a handoff cannot recreate it.
        .id(video.id)
    }

    private func downloadable(_ option: StreamOption) -> Bool {
        let live = media.type == "tv" || media.behaviorHints?.isLive == true
        return DownloadPolicy.supportsUsenet(option.source, live: live)
            || (try? DownloadPolicy.url(for: option.source, live: live)) != nil
    }
    private var options: [StreamOption] {
        intent == .download ? result.options.filter(downloadable) : result.options
    }
    private func download(_ option: StreamOption) {
        guard !launching else { return }
        launching = true
        Task {
            defer { launching = false }
            do {
                try await store.downloads.enqueue(media: media, video: video, option: option)
                if !store.contains(media) { store.toggleLibrary(media) }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard playbackRequest == nil else { return }
        await model.load(key: media.type + ":" + video.id + store.addonRevision.uuidString) { update in
            await store.streamOptions(
                type: media.type, videoID: video.id, embedded: video.embedded, onUpdate: update)
        }
    }

    private func loadNZBFinder(refresh: Bool = false) async {
        guard nzbfinder.enabled else { indexer.clear(); packs.clear(); return }
        do {
            let context = try NZBSearchContext(media: media, episode: video.episode, details: details)
            let service = nzbfinder
            async let individual: Void = indexer.load { cursor in
                try await service.search(context, cursor: cursor, refresh: refresh)
            }
            if context.isEpisode, service.includeSeasonPacks {
                let pack = try NZBSearchContext(
                    media: media, episode: video.episode, details: details, seasonPack: true)
                await packs.load { cursor in try await service.search(pack, cursor: cursor, refresh: refresh)
                }
            } else {
                packs.clear()
            }
            await individual
        } catch { indexer.clear(error: error.localizedDescription); packs.clear() }
    }

    private func play(_ option: StreamOption, player: VideoPlayer? = nil) {
        guard !launching else { return }
        launching = true
        launchingUsenet = option.nzbRelease != nil || option.source.nzbUrl != nil
        launchTask = Task {
            defer { launching = false; launchingUsenet = false }
            do {
                if let release = option.nzbRelease {
                    playbackOption = option
                    await usenet.prepareNZB(
                        name: release.title, episodeTarget: episodeTarget,
                        fetch: { try await nzbfinder.nzb(release) }
                    ) { url, _ in
                        makePlaybackRequest(url)
                    }
                    return
                }
                let source = try await store.freshSource(option, type: media.type, videoID: video.id)
                try Task.checkCancellation()
                if case .usenet = try StreamResolver.resolve(source) {
                    playbackOption = option
                    await usenet.prepare(source: source, episodeTarget: episodeTarget) { url, _ in
                        makePlaybackRequest(url)
                    }
                } else {
                    open(source, option: option, player: player)
                }
            } catch is CancellationError {} catch {
                self.error = error.localizedDescription
                if error is PlaybackError { await load() }
            }
        }
    }

    private func open(_ source: StreamSource, option: StreamOption, player: VideoPlayer?) {
        do {
            switch try StreamResolver.resolve(source) {
            case .native(let url):
                store.refreshPlayers()
                let player = player ?? store.preferredPlayer
                guard store.availablePlayers.contains(player) else {
                    error = "Install Infuse, Outplayer, or VLC to play videos."
                    return
                }
                if player.isInternal {
                    playbackOption = option
                    playbackRequest = makePlaybackRequest(url)
                    return
                }
                let launch = try player.launchURL(for: url)
                openURL(launch) { accepted in
                    if !accepted {
                        store.refreshPlayers()
                        error = "Couldn’t open \(player.title). Install it or select another player."
                    }
                }
            case .usenet:
                error = "Use the built-in player for Usenet sources."
            case .external(let url):
                openURL(url) { accepted in
                    if !accepted { error = "Couldn’t open the external link." }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func makePlaybackRequest(_ url: URL) -> PlaybackRequest {
        PlaybackRequest(
            url: url, title: media.name, subtitle: video.title,
            artworkURL: (media.poster ?? video.episode?.thumbnail ?? media.background).flatMap {
                try? AddonURL.http($0)
            },
            isLive: media.behaviorHints?.isLive == true || media.type == "tv",
            resumeSeconds: store.watchProgress.resumePosition(for: media, videoID: video.id),
            onProgress: { [store, media, video] update in
                store.recordPlayback(media: media, video: video, update: update)
            },
            onScrobble: { [store, media, video] event in
                store.scrobble(event, media: media, videoID: video.id)
            },
            loadUpNext: { [store, media, video, episodes, details] in
                try await store.nextEpisode(
                    for: media, video: video, knownEpisodes: episodes, details: details)
            },
            onNextEpisode: { episode in pendingHandoff = .episode(episode) },
            loadIntroSegment: { [store, media, video, episodes] in
                try await store.introSegment(for: media, video: video, knownEpisodes: episodes)
            }, introSkippingEnabled: { [store] in store.showSkipIntro })
    }
    private func finishPlayback() {
        let option = playbackOption
        let handoff = pendingHandoff
        playbackOption = nil
        pendingHandoff = nil
        switch handoff {
        case .episode(let episode):
            downloadRouter.route(
                media: media, video: VideoSelection(episode: episode), store: store, knownEpisodes: episodes
            ) {
                video = VideoSelection(episode: episode)
            }
        case .player(let player):
            // Refresh expiring provider URLs before retries or external handoffs.
            if let option { play(option, player: player) }
        case nil: break
        }
    }
}
