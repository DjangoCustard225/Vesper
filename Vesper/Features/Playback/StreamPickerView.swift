import SwiftUI
import VesperCore

struct StreamPickerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let media: MediaItem
    @State private var video: VideoSelection
    @State private var model = StreamLoadingController()

    private var result: StreamResults { model.result }

    private var loading: Bool { model.loading }
    @State private var error: String?
    @State private var launchTask: Task<Void, Never>?
    @State private var launching = false
    @State private var playbackRequest: PlaybackRequest?
    @State private var playbackOption: StreamOption?
    private enum PlaybackHandoff {
        case player(VideoPlayer)
        case episode(Episode)
    }
    @State private var pendingHandoff: PlaybackHandoff?
    private let episodes: [Episode]
    private let details: MetadataEnrichment?

    init(
        media: MediaItem, video: VideoSelection, episodes: [Episode] = [], details: MetadataEnrichment? = nil
    ) {
        self.media = media
        _video = State(initialValue: video)
        self.episodes = episodes
        self.details = details
    }

    var body: some View {
        NavigationStack {
            sources.navigationTitle("Choose a stream").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task(id: video.id + store.addonRevision.uuidString) { await load() }
                .onChange(of: store.addonRevision) { _, _ in launchTask?.cancel() }
                .onDisappear {
                    model.cancel()
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
                    "Unable to play",
                    isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
                ) {
                    Button("OK") { error = nil }
                } message: {
                    Text(error ?? "")
                }
        }
    }

    private var sources: some View {
        @Bindable var store = store
        return SourceResultsScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(media.name).font(.title3.bold())
                if let title = video.title { Text(title).font(.subheadline).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
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
            if loading { ProgressView("Finding streams…").frame(maxWidth: .infinity).padding(.vertical, 30) }
            if !loading && result.options.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "No streams found", systemImage: "play.slash",
                        description: Text(
                            "Install a stream add-on in Settings → Add-ons. TMDB supplies details, artwork, and episode information."
                        ))
                    Button("Try again") { Task { await load() } }.buttonStyle(.glass).frame(
                        maxWidth: .infinity)
                }
            }
            if !result.options.isEmpty {
                Text("Available sources").font(.headline).padding(.horizontal, 2).padding(.top, 12).padding(
                    .bottom, 4)
                ForEach(result.options) { option in
                    SourceResultCard(option: option) { play(option) }
                        .disabled(launching)
                        .contextMenu {
                            ForEach(store.availablePlayers) { player in
                                Button("Play in \(player.title)", systemImage: "play") {
                                    play(option, player: player)
                                }
                            }
                        }
                        .modifier(SourceCardScrollEffect())
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
    }

    private func load() async {
        guard playbackRequest == nil else { return }
        await model.load(key: media.type + ":" + video.id + store.addonRevision.uuidString) { update in
            await store.streamOptions(
                type: media.type, videoID: video.id, embedded: video.embedded, onUpdate: update)
        }
    }

    private func play(_ option: StreamOption, player: VideoPlayer? = nil) {
        guard !launching else { return }
        launching = true
        launchTask = Task {
            defer { launching = false }
            do {
                let source = try await store.freshSource(option, type: media.type, videoID: video.id)
                try Task.checkCancellation()
                open(source, option: option, player: player)
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
                    playbackRequest = PlaybackRequest(
                        url: url, title: media.name, subtitle: video.title,
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
                    return
                }
                let launch = try player.launchURL(for: url)
                openURL(launch) { accepted in
                    if !accepted {
                        store.refreshPlayers()
                        error = "Couldn’t open \(player.title). Install it or select another player."
                    }
                }
            case .external(let url):
                openURL(url) { accepted in
                    if !accepted { error = "Couldn’t open the external link." }
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func finishPlayback() {
        let option = playbackOption
        let handoff = pendingHandoff
        playbackOption = nil
        pendingHandoff = nil
        switch handoff {
        case .episode(let episode):
            video = VideoSelection(episode: episode)
        case .player(let player):
            // Refresh expiring provider URLs before retries or external handoffs.
            if let option { play(option, player: player) }
        case nil: break
        }
    }
}
