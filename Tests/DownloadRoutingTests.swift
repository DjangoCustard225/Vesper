import Foundation
import Observation
import VesperCore

// ACTUAL_VIDEO
// ACTUAL_REQUEST
// ACTUAL_ROUTER

@MainActor final class DownloadsDouble {
    var completed: [DownloadRecord] = []
    var missing = false
    var slowValidation = false
    var leases = DownloadFileLeases()
    func ready() async {}
    func candidates(media: MediaItem, video: VideoSelection) -> [DownloadRecord] {
        completed.filter {
            DownloadPlayback.matches($0, media: media, videoID: video.id, episode: video.episode)
        }
    }
    func acquire(_ id: UUID) -> Bool { leases.acquire([id]); return true }
    func validatedURL(_ record: DownloadRecord) async -> URL? {
        if slowValidation { try? await Task.sleep(for: .milliseconds(20)) }
        return missing ? nil : URL(fileURLWithPath: "/saved/" + record.id.uuidString + ".mkv")
    }
    func unprotect(_ ids: Set<UUID>) { leases.release(ids) }
    func localArtwork(_ raw: String?, record: DownloadRecord) -> URL? { nil }
}
struct HistoryDouble {
    func resumePosition(for: MediaItem, videoID: String) -> Double { 42 }
}
@MainActor final class AppStore {
    let downloads = DownloadsDouble()
    let watchProgress = HistoryDouble()
    func recordPlayback(media: MediaItem, video: VideoSelection, update: PlaybackProgressUpdate) {}
    func scrobble(_ event: TraktScrobbleEvent, media: MediaItem, videoID: String) {}
    func isWatched(_ media: MediaItem, episode: Episode) -> Bool { false }
}
@main @MainActor struct RoutingRegression {
    static func main() async throws {
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); passed += 1
        }
        func settle(_ condition: () -> Bool) async throws {
            for _ in 0..<1000 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            preconditionFailure("Playback routing did not settle")
        }
        func record(_ number: Int? = nil) throws -> DownloadRecord {
            let media = MediaItem(
                id: "tt1", type: number == nil ? "movie" : "series", name: "Title", poster: nil)
            let ep = try number.map { n in
                try JSONDecoder().decode(
                    Episode.self, from: Data("{\"id\":\"tt1:1:\(n)\",\"season\":1,\"episode\":\(n)}".utf8))
            }
            let source = try JSONDecoder().decode(
                StreamSource.self, from: Data(#"{"url":"https://files.example/movie.mkv"}"#.utf8))
            var value = DownloadRecord(
                media: media, videoID: ep?.id ?? media.id, subtitle: nil, episode: ep, source: source,
                providerID: nil, fetchedAt: Date())
            value.phase = .completed; value.receivedBytes = 8; value.fileName = value.id.uuidString + ".mkv"
            return value
        }
        do {
            let store = AppStore(), router = DownloadPlaybackRouter(), saved = try record()
            store.downloads.completed = [saved]
            var online = 0
            router.route(
                media: saved.media, video: VideoSelection(id: saved.videoID, title: nil, embedded: nil),
                store: store
            ) { online += 1 }
            try await settle { router.request != nil }
            check(
                online == 0 && router.request?.url.isFileURL == true, "Local playback bypasses online sources"
            )
            check(
                router.request?.resumeSeconds == 42 && router.request?.onProgress != nil
                    && router.request?.onScrobble != nil,
                "Local playback retains resume, history and scrobbling")
            check(store.downloads.leases.ids == [saved.id], "Playing protects the local file")
            router.request = nil; router.dismissed(store: store)
            check(store.downloads.leases.ids.isEmpty, "Dismissal releases its file lease")
        }
        do {
            let store = AppStore(), router = DownloadPlaybackRouter(), saved = try record()
            var online = false
            router.route(
                media: saved.media, video: VideoSelection(id: saved.videoID, title: nil, embedded: nil),
                store: store
            ) { online = true }
            try await settle { online }
            check(
                router.request == nil && store.downloads.leases.ids.isEmpty,
                "Missing downloads take the ordinary online route")
        }
        do {
            let store = AppStore(), router = DownloadPlaybackRouter(), saved = try record()
            store.downloads.completed = [saved]; store.downloads.missing = true
            var online = false
            router.route(
                media: saved.media, video: VideoSelection(id: saved.videoID, title: nil, embedded: nil),
                store: store
            ) { online = true }
            try await settle { router.failure != nil }
            check(
                !online && router.request == nil && store.downloads.leases.ids.isEmpty,
                "A missing saved file shows an error without silently streaming")
            router.online?()
            check(online, "Streaming requires the explicit recovery action")
        }
        do {
            let store = AppStore(), router = DownloadPlaybackRouter(), one = try record(), two = try record()
            store.downloads.completed = [one, two]
            router.route(
                media: one.media, video: VideoSelection(id: one.videoID, title: nil, embedded: nil),
                store: store)
            try await settle { router.versions.count == 2 }
            check(router.request == nil, "Multiple versions require a native choice")
            router.versions = []; router.play(two, store: store)
            try await settle { router.request != nil }
            check(
                router.request?.url.lastPathComponent == two.id.uuidString + ".mkv",
                "The selected version is played exactly")
            router.request = nil; router.dismissed(store: store)
        }
        do {
            let store = AppStore(), router = DownloadPlaybackRouter(), one = try record(1),
                two = try record(2)
            store.downloads.completed = [one, two]
            router.play(one, store: store)
            try await settle { router.request != nil }
            let next = try await router.request?.loadUpNext?()
            check(next?.id == two.episode?.id, "Offline Up Next offers the contiguous downloaded episode")
            if let next { router.request?.onNextEpisode?(next) }
            router.request = nil; router.dismissed(store: store)
            try await settle { router.request?.url.lastPathComponent == two.id.uuidString + ".mkv" }
            check(store.downloads.leases.ids == [two.id], "Up Next hands off the lease to the new episode")
            router.request = nil; router.dismissed(store: store)
        }
        do {
            let store = AppStore(), router = DownloadPlaybackRouter(), saved = try record()
            store.downloads.completed = [saved]; store.downloads.slowValidation = true
            router.play(saved, store: store); router.cancel()
            try await settle { store.downloads.leases.ids.isEmpty }
            check(
                router.request == nil,
                "Cancellation while opening releases its lease and never presents a stale player")
        }
        do {
            var router: DownloadPlaybackRouter? = DownloadPlaybackRouter()
            weak var released = router
            router?.online = { [instance = router!] in _ = instance.failure }
            router?.cancel(); router = nil
            check(released == nil, "Leaving a detail page clears callbacks that capture its state")
            released = nil
        }
        print("Passed \(passed) download routing regression checks.")
    }
}
