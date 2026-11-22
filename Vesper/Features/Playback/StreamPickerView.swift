import SwiftUI
import VesperCore
import UsenetEngine

enum StreamPickerIntent { case playback, download }

@MainActor @Observable private final class UsenetLaunchStatus {
    var active = false
    /// Mirrors the picker's launch task so it can be cancelled when the picker is torn down.
    @ObservationIgnored var task: Task<Void, Never>?
}

/// `onDisappear` also fires while the preparation cover hides the picker, so it cannot tell
/// "covered" from "gone". This view is only dismantled when the picker itself is removed.
private struct LaunchLifetime: UIViewRepresentable {
    let status: UsenetLaunchStatus
    func makeCoordinator() -> UsenetLaunchStatus { status }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: UsenetLaunchStatus) {
        coordinator.task?.cancel()
        coordinator.task = nil
    }
}

struct StreamPickerView: View {
    @State private var showingPreparation = false
    @State private var preparationPresented = false
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let media: MediaItem
    let intent: StreamPickerIntent
    @State private var video: VideoSelection
    @State private var model = StreamLoadingController()

    @State private var indexer = NZBFinderSearchController()
    @State private var packs = NZBFinderSearchController()
    private var nzbfinder: NZBFinderService { .shared }
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
    @State private var query = ""
    @State private var fullName: SourceName?
    private struct SourceName: Identifiable {
        let id = UUID()
        let value: String
    }
    @State private var launchTask: Task<Void, Never>?
    @State private var launchRevision = UUID()
    @State private var launching = false
    @State private var launchStatus = UsenetLaunchStatus()
    private var launchingUsenet: Bool {
        get { launchStatus.active }
        nonmutating set { launchStatus.active = newValue }
    }
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
            sources.accessibilityHidden(launchingUsenet || usenet.preparing).navigationTitle(
                intent == .download ? "Choose a download" : "Choose a stream"
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(launchingUsenet || usenet.preparing ? .hidden : .visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(role: .close) { dismiss() } } }
            .task(id: video.id + store.addonRevision.uuidString) { await load() }
            .task(id: video.id + nzbfinder.revision.uuidString) { await loadNZBFinder() }
            .onChange(of: store.addonRevision) { _, _ in launchTask?.cancel() }
            .onChange(of: video.id) { _, _ in query = "" }
            .onDisappear {
                model.cancel()
                indexer.cancel(); packs.cancel()
                if !preparationPresented { launchTask?.cancel() }
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
                isPresented: Binding(
                    get: { error != nil && !preparationPresented }, set: { if !$0 { error = nil } })
            ) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .onChange(of: launchingUsenet || usenet.preparing) { _, preparing in
            if preparing { preparationPresented = true }
            showingPreparation = preparing
        }
        .background {
            UsenetPreparationScreen(
                isPresented: showingPreparation,
                isActive: {
                    let preparing = usenet.preparing
                    return launchingUsenet || preparing
                },
                currentStage: { usenet.preparing ? usenet.stage : .preparing },
                content: UsenetPreparationView(
                    title: media.name, subtitle: video.title,
                    poster: media.poster, backdrop: media.background,
                    stage: usenet.preparing ? usenet.stage : .preparing, cancel: cancelUsenetPreparation
                ), onDismiss: { if preparationPresented { preparationPresented = false } })
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: launchingUsenet || usenet.preparing)
        .background { LaunchLifetime(status: launchStatus).frame(width: 0, height: 0) }
        .downloadedPlayback(downloadRouter, knownEpisodes: episodes)
        .usenetPlayback(
            usenet, showsErrorAlert: false, presentationReady: !preparationPresented,
            onDismiss: finishPlayback
        )
        .sheet(item: $fullName) { name in
            ScrollView {
                Text(name.value).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(24)
            }.appScrollEdges().presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
    }

    private var sources: some View {
        // Built once per update; each list below reads these instead of rebuilding them.
        let releases = indexerReleases
        let result = StreamResults(
            options: model.result.options + releases.map(\.streamOption), failures: model.result.failures)
        let options = intent == .download ? result.options.filter(downloadable) : result.options
        let visible = Self.matching(options, query: query)
        let saved = store.downloads.records.filter {
            $0.videoID == video.id && $0.media.isSameTitle(as: media)
        }
        return SourceResultsScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(media.name).font(.title3.bold())
                if let title = video.title { Text(title).font(.subheadline).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            if !options.isEmpty || !query.isEmpty { searchField }
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
            if indexer.hasSearched, !indexer.loading, !packs.loading, releases.isEmpty,
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
            if !options.isEmpty && visible.isEmpty {
                Text("No sources match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            if !visible.isEmpty {
                Text("Available sources").font(.headline).padding(.horizontal, 2).padding(.top, 12).padding(
                    .bottom, 4)
                ForEach(visible) { option in
                    SourceResultCard(
                        option: option,
                        action: { if intent == .download { download(option) } else { play(option) } },
                        isDownloadMode: intent == .download,
                        isInDownloads: saved.contains {
                            StreamPolicy.refreshedMatch(for: $0.source, in: [option.source]) != nil
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
    /// Sources whose name, details or add-on contain every word typed in the search field.
    private static func matching(_ options: [StreamOption], query: String) -> [StreamOption] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return options }
        return options.filter { option in
            let text = [
                option.displayName, option.source.label,
                option.source.description ?? option.source.title ?? "",
                option.addonName,
            ].joined(separator: " ")
            return terms.allSatisfy {
                text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search sources", text: $query)
                .textFieldStyle(.plain).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffect(.regular, in: Capsule())
    }
    private func download(_ option: StreamOption) {
        guard !launching else { return }
        launching = true
        Task {
            defer { launching = false }
            do {
                try await store.downloads.enqueue(media: media, video: video, option: option)
                store.addToLibrary(media)
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

    private func cancelUsenetPreparation() {
        launchRevision = UUID()
        launchTask?.cancel()
        launchTask = nil
        launching = false
        launchingUsenet = false
        usenet.cancel()
    }

    private func play(_ option: StreamOption, player: VideoPlayer? = nil) {
        guard !launching else { return }
        launching = true
        let revision = UUID()
        launchRevision = revision
        launchingUsenet = option.nzbRelease != nil || option.source.nzbUrl != nil
        launchTask = Task {
            defer {
                if launchRevision == revision { launching = false; launchingUsenet = false }
            }
            do {
                if let release = option.nzbRelease {
                    playbackOption = option
                    await usenet.prepareNZB(
                        name: release.title, episodeTarget: episodeTarget,
                        fetch: { try await nzbfinder.nzb(release) }
                    ) { url, file in
                        makeUsenetPlaybackRequest(url, file: file)
                    }
                    return
                }
                let source = try await store.freshSource(option, type: media.type, videoID: video.id)
                try Task.checkCancellation()
                if case .usenet = try StreamResolver.resolve(source) {
                    playbackOption = option
                    await usenet.prepare(source: source, episodeTarget: episodeTarget) { url, file in
                        makeUsenetPlaybackRequest(url, file: file)
                    }
                } else {
                    open(source, option: option, player: player)
                }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, launchRevision == revision else { return }
                self.error = error.localizedDescription
                if error is PlaybackError { await load() }
            }
        }
        launchStatus.task = launchTask
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
    private func makeUsenetPlaybackRequest(_ url: URL, file: UsenetVideo) -> PlaybackRequest {
        guard media.type == "series" else { return makePlaybackRequest(url) }
        if let selected = video.matchingUsenetFile(file, episodes: episodes) {
            return makePlaybackRequest(url, selection: selected)
        }
        // Unknown filenames remain playable without guessing resume, subtitle or tracking IDs.
        return PlaybackRequest(url: url, title: media.name, subtitle: file.name)
    }

    private func makePlaybackRequest(_ url: URL, selection: VideoSelection? = nil) -> PlaybackRequest {
        let video = selection ?? self.video
        return PlaybackRequest(
            url: url, title: media.name, subtitle: video.title,
            artworkURL: (media.poster ?? video.episode?.thumbnail ?? media.background).flatMap {
                try? AddonURL.http($0)
            },
            isLive: media.behaviorHints?.isLive == true || media.type == "tv",
            subtitleMedia: media, subtitleVideoID: video.id,
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
