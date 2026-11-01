import SwiftUI
import VesperCore

/// Every playback entry uses this local-first route. Online source choice stays explicit.
@MainActor @Observable final class DownloadPlaybackRouter {
    var request: PlaybackRequest?
    var versions: [DownloadRecord] = []
    var failure: String?
    var online: (() -> Void)?
    private var playing: UUID?
    private var pendingNext: Episode?
    private var operation: Task<Void, Never>?
    private var choosing = false

    func route(
        media: MediaItem, video: VideoSelection, store: AppStore, knownEpisodes: [Episode] = [],
        online: (() -> Void)? = nil
    ) {
        guard request == nil, !choosing else { return }
        choosing = true; self.online = online
        operation = Task {
            await store.downloads.ready()
            guard !Task.isCancelled else { choosing = false; return }
            let candidates = store.downloads.candidates(media: media, video: video)
            choosing = false
            if candidates.isEmpty {
                if let online { online() } else { failure = DownloadFailure.missing.localizedDescription }
            } else if candidates.count > 1 {
                versions = candidates
            } else if let record = candidates.first {
                play(record, store: store, knownEpisodes: knownEpisodes)
            }
        }
    }
    func play(_ record: DownloadRecord, store: AppStore, knownEpisodes: [Episode] = []) {
        guard !choosing, request == nil else { return }
        guard store.downloads.acquire(record.id) else {
            failure = DownloadFailure.missing.localizedDescription; return
        }
        choosing = true
        operation = Task { [self] in
            guard let url = await store.downloads.validatedURL(record), !Task.isCancelled else {
                store.downloads.unprotect([record.id]); choosing = false
                if !Task.isCancelled { failure = DownloadFailure.missing.localizedDescription }
                return
            }
            choosing = false; playing = record.id
            let media = record.media
            nextMedia = media
            let historyID = record.episode?.watchHistoryID(for: media) ?? record.videoID
            let video = VideoSelection(
                id: historyID, title: record.subtitle, embedded: nil, episode: record.episode)
            request = PlaybackRequest(
                url: url, title: media.name, subtitle: record.subtitle,
                artworkURL: store.downloads.localArtwork(media.poster, record: record),
                resumeSeconds: max(
                    store.watchProgress.resumePosition(for: media, videoID: historyID),
                    store.watchProgress.resumePosition(for: media, videoID: record.videoID)),
                onProgress: { store.recordPlayback(media: media, video: video, update: $0) },
                onScrobble: { store.scrobble($0, media: media, videoID: historyID) },
                loadUpNext: {
                    guard let current = record.episode else { return nil }
                    let saved = store.downloads.completed.filter { $0.media.isSameTitle(as: media) }
                    let known = knownEpisodes.isEmpty ? saved.compactMap(\.episode) : knownEpisodes
                    return DownloadPlayback.next(
                        after: current, known: known, downloaded: saved, media: media,
                        isWatched: { store.isWatched(media, episode: $0) })
                }, onNextEpisode: { [weak self] in self?.pendingNext = $0 }, introSkippingEnabled: { false })
        }
    }
    func dismissed(store: AppStore) {
        online = nil
        if let playing { store.downloads.unprotect([playing]) }; playing = nil
        if let next = pendingNext {
            pendingNext = nil
            if let media = nextMedia {
                route(media: media, video: VideoSelection(episode: next), store: store)
            }
        }
    }
    private var nextMedia: MediaItem?
    func cancel() {
        operation?.cancel(); operation = nil
        online = nil
        if request == nil { versions = [] }
    }
}

struct DownloadPlaybackPresentation: ViewModifier {
    @Environment(AppStore.self) private var store
    @Bindable var router: DownloadPlaybackRouter
    var knownEpisodes: [Episode] = []
    func body(content: Content) -> some View {
        content.background {
            BuiltInPlayerPresentation(
                request: $router.request, gesturePreferences: store.playerGestures,
                players: [.aether], onDismiss: { router.dismissed(store: store) }
            ) { _ in }
        }
        .confirmationDialog(
            "Choose a download",
            isPresented: Binding(get: { !router.versions.isEmpty }, set: { if !$0 { router.versions = [] } }),
            titleVisibility: .visible
        ) {
            ForEach(router.versions) { record in
                Button(
                    (record.source.behaviorHints?.filename ?? record.source.name ?? "Downloaded file") + " · "
                        + ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file)
                ) {
                    router.versions = []; router.play(record, store: store, knownEpisodes: knownEpisodes)
                }
            }
        }
        .alert(
            "Download unavailable",
            isPresented: Binding(get: { router.failure != nil }, set: { if !$0 { router.failure = nil } })
        ) {
            if let online = router.online { Button("Choose Online Source", action: online) }
            Button("Cancel", role: .cancel) { router.failure = nil }
        } message: {
            Text(router.failure ?? "")
        }
        .onDisappear { router.cancel() }
    }
}

extension View {
    func downloadedPlayback(_ router: DownloadPlaybackRouter, knownEpisodes: [Episode] = []) -> some View {
        modifier(DownloadPlaybackPresentation(router: router, knownEpisodes: knownEpisodes))
    }
}
