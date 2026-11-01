import SwiftUI
import UIKit
import UsenetEngine
import VesperCore

@MainActor @Observable final class UsenetPlaybackCoordinator {
    var request: PlaybackRequest?
    var choices: [UsenetVideo] = []
    var error: String?
    private(set) var preparing = false
    private(set) var readingFile = false
    private(set) var importedName: String?
    private var token: UUID?
    private var selected: UsenetVideo?
    private var episodeTarget: UsenetEpisodeTarget?
    private var makeRequest: ((URL, UsenetVideo) -> PlaybackRequest)?
    private var operation: Task<Void, Never>?

    func prepare(
        source: StreamSource? = nil, data: Data? = nil, episodeTarget: UsenetEpisodeTarget? = nil,
        makeRequest: @escaping (URL, UsenetVideo) -> PlaybackRequest
    ) async {
        guard request == nil else { return }
        let token = begin(makeRequest: makeRequest)
        importedName = nil
        self.episodeTarget = episodeTarget
        await loadVideos(token: token, source: source, data: data)
    }

    /// Selection starts an owned import immediately. Sheet dismissal never controls whether work runs.
    func importFile(_ url: URL, makeRequest: @escaping (URL, UsenetVideo) -> PlaybackRequest) {
        guard request == nil else { return }
        let token = begin(makeRequest: makeRequest)
        importedName = url.lastPathComponent
        readingFile = true
        operation = Task {
            do {
                let data = try await Task.detached { try UsenetService.importFile(url) }.value
                try Task.checkCancellation()
                guard self.token == token else { return }
                readingFile = false
                await loadVideos(token: token, data: data)
            } catch {
                await failed(error, token: token, fallback: "The NZB file could not be opened.")
            }
        }
    }

    func prepareNZB(
        name: String, episodeTarget: UsenetEpisodeTarget? = nil,
        fetch: @escaping @MainActor () async throws -> NZBDownload,
        makeRequest: @escaping (URL, UsenetVideo) -> PlaybackRequest
    ) async {
        guard request == nil else { return }
        let token = begin(makeRequest: makeRequest)
        importedName = name
        self.episodeTarget = episodeTarget
        do {
            let download = try await fetch()
            try Task.checkCancellation()
            guard self.token == token else { return }
            await loadVideos(
                token: token, data: download.data, passwords: download.password.map { [$0] } ?? [])
        } catch {
            await failed(error, token: token, fallback: "The NZB could not be retrieved.")
        }
    }

    private func begin(makeRequest: @escaping (URL, UsenetVideo) -> PlaybackRequest) -> UUID {
        cancel()
        let token = UUID()
        self.token = token; self.makeRequest = makeRequest; preparing = true; error = nil
        return token
    }

    private func loadVideos(
        token: UUID, source: StreamSource? = nil, data: Data? = nil, passwords: [String] = []
    ) async {
        do {
            let catalog = try await UsenetService.shared.prepare(
                token: token, source: source, data: data, name: importedName, passwords: passwords)
            let matched = episodeTarget.map { target in catalog.filter(target.matches) } ?? []
            let videos = matched.isEmpty ? catalog : matched
            try Task.checkCancellation()
            guard self.token == token else { return }
            if videos.count == 1, let video = videos.first, episodeTarget == nil || matched.count == 1 {
                await play(video, token: token)
            } else {
                choices = videos; preparing = false
            }
        } catch {
            await failed(
                error, token: token,
                fallback: "Usenet playback could not start. Check the provider and try again.")
        }
    }

    func choose(_ video: UsenetVideo) { selected = video; choices = [] }
    func finishChoosing() {
        guard let token, let video = selected else { cancel(); return }
        selected = nil; preparing = true
        operation = Task { await self.play(video, token: token) }
    }
    private func play(_ video: UsenetVideo, token: UUID) async {
        do {
            let url = try await UsenetService.shared.open(video, token: token) { [weak self] message in
                self?.error = message
            }
            try Task.checkCancellation()
            guard self.token == token else { return }
            request = makeRequest?(url, video); preparing = false
        } catch {
            await failed(error, token: token, fallback: "The local video stream could not start.")
        }
    }
    private func failed(_ failure: Error, token: UUID, fallback: String) async {
        guard self.token == token else { return }
        preparing = false; readingFile = false
        if !(failure is CancellationError) {
            error =
                (failure as? UsenetError)?.localizedDescription ?? (failure as? NZBFinderError)?
                .localizedDescription ?? fallback
        }
        await UsenetService.shared.stop(token)
    }
    func finished() { request = nil; cancel() }
    func cancel() {
        operation?.cancel(); operation = nil
        let previous = token; token = nil; selected = nil; choices = []; preparing = false;
        readingFile = false; makeRequest = nil; episodeTarget = nil
        Task { await UsenetService.shared.stop(previous) }
    }
}

private struct UsenetPlaybackPresentation: ViewModifier {
    @Environment(AppStore.self) private var store
    @Bindable var coordinator: UsenetPlaybackCoordinator
    let onDismiss: () -> Void
    let showsErrorAlert: Bool
    func body(content: Content) -> some View {
        content.background {
            UsenetPlaybackLifetime(playback: coordinator).frame(width: 0, height: 0)
            BuiltInPlayerPresentation(
                request: $coordinator.request, gesturePreferences: store.playerGestures, players: [.aether],
                onDismiss: {
                    coordinator.finished(); onDismiss()
                }
            ) { _ in }
        }
        .sheet(
            isPresented: Binding(
                get: { !coordinator.choices.isEmpty }, set: { if !$0 { coordinator.choices = [] } }),
            onDismiss: { coordinator.finishChoosing() }
        ) {
            NavigationStack {
                List(coordinator.choices) { video in
                    Button {
                        coordinator.choose(video)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(video.name).foregroundStyle(.primary)
                            Text(ByteCountFormatter.string(fromByteCount: video.length, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: Design.minimumHitTarget, alignment: .leading)
                    }
                }.navigationTitle("Choose a Video").navigationBarTitleDisplayMode(.inline)
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .alert(
            "Usenet",
            isPresented: Binding(
                get: { showsErrorAlert && coordinator.error != nil },
                set: { if showsErrorAlert && !$0 { coordinator.error = nil } })
        ) {
            Button("OK") { coordinator.error = nil }
        } message: {
            Text(coordinator.error ?? "")
        }
    }
}
/// Covering the page with a picker or player must not cancel its work. Removal from navigation does.
private struct UsenetPlaybackLifetime: UIViewRepresentable {
    let playback: UsenetPlaybackCoordinator
    func makeCoordinator() -> UsenetPlaybackCoordinator { playback }
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {}
    static func dismantleUIView(_ view: UIView, coordinator: UsenetPlaybackCoordinator) {
        coordinator.finished()
    }
}

extension View {
    func usenetPlayback(
        _ coordinator: UsenetPlaybackCoordinator, showsErrorAlert: Bool = true,
        onDismiss: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            UsenetPlaybackPresentation(
                coordinator: coordinator, onDismiss: onDismiss, showsErrorAlert: showsErrorAlert))
    }
}
