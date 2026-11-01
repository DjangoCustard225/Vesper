import Foundation
import Observation
import UsenetEngine
import VesperCore

#if os(Linux)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() {}
}
#endif
struct PlaybackRequest {
    let url: URL
    let title: String
}
@MainActor final class UsenetService {
    static let shared = UsenetService()
    var failure: UsenetError?
    var provider: UsenetProvider?
    var received: [Data] = []
    var receivedPasswords: [String] = []
    var receivedName: String?
    var videos = [UsenetVideo(id: 0, name: "Movie.mp4", extents: [])]
    func prepare(token: UUID, source: StreamSource?, data: Data?, name: String?, passwords: [String])
        async throws -> [UsenetVideo]
    {
        try Task.checkCancellation()
        if let failure { throw failure }
        received.append(data ?? Data()); receivedPasswords = passwords; receivedName = name
        return videos
    }
    func open(_ video: UsenetVideo, token: UUID, onFailure: @escaping @MainActor @Sendable (String) -> Void)
        async throws -> URL
    {
        URL(string: "http://127.0.0.1:1234/video\(video.id).mp4")!
    }
    func stop(_ token: UUID?) async {}
    // ACTUAL_READER
}
@MainActor final class IndexerClientDouble {
    var calls = 0
    func download(_ release: NZBRelease, apiKey: String) async throws -> NZBDownload {
        calls += 1; return NZBDownload(data: Data("indexer bytes".utf8), password: "embedded-secret")
    }
}
@MainActor final class IndexerServiceDouble {
    var enabled = true
    var apiKey: String? = "test-key"
    var revision = UUID()
    let client = IndexerClientDouble()
    // ACTUAL_RETRIEVAL
}
// ACTUAL_DISPLAY_NAME
// ACTUAL_COORDINATOR

@main @MainActor struct ImportRegression {
    static func main() async throws {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); passed += 1
        }
        func settle(_ condition: () -> Bool) async throws {
            for _ in 0..<1000 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(1))
            }
            preconditionFailure("Import did not settle")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ name: String, _ bytes: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(bytes.utf8).write(to: url); return url
        }
        let service = UsenetService.shared
        let request: (URL, UsenetVideo) -> PlaybackRequest = { PlaybackRequest(url: $0, title: $1.name) }
        do {
            let model = UsenetPlaybackCoordinator(), url = try file("selected.nzb", "selected bytes")
            model.importFile(url, makeRequest: request)
            check(model.preparing && model.readingFile, "Selection immediately exposes import activity")
            check(model.importedName == "selected.nzb", "Selection exposes the chosen filename")
            // No picker dismissal callback is sent. Import must still reach playback.
            try await settle { model.request != nil }
            check(
                service.received.last == Data("selected bytes".utf8),
                "Selected bytes reach preparation directly")
            check(!model.preparing && !model.readingFile, "Import progress finishes")
            model.finished()
            check(model.request == nil, "Removal stops playback")
        }
        do {
            service.failure = .providerRequired
            let model = UsenetPlaybackCoordinator()
            model.importFile(try file("provider.nzb", "provider bytes"), makeRequest: request)
            try await settle { model.error != nil }
            check(
                model.error == UsenetError.providerRequired.localizedDescription,
                "Missing provider has a visible error")
            check(!model.preparing && !model.readingFile, "Provider failure clears progress")
            service.failure = nil; model.finished()
        }
        do {
            let model = UsenetPlaybackCoordinator(), before = service.received.count
            model.importFile(try file("empty.nzb", ""), makeRequest: request)
            try await settle { model.error != nil }
            check(model.error == UsenetError.invalidNZB.localizedDescription, "Empty import reports an error")
            check(service.received.count == before, "Invalid input never reaches the backend")
            model.finished()
        }
        do {
            let model = UsenetPlaybackCoordinator()
            model.importFile(directory.appendingPathComponent("missing.nzb"), makeRequest: request)
            try await settle { model.error != nil }
            check(
                model.error == "The NZB file could not be opened.",
                "Read failure is shown without exposing paths")
            model.finished()
        }
        do {
            let model = UsenetPlaybackCoordinator(), before = service.received.count
            model.importFile(try file("cancel.nzb", "cancelled bytes"), makeRequest: request)
            model.cancel()
            try await Task.sleep(for: .milliseconds(20))
            check(model.request == nil && !model.preparing && !model.readingFile, "Cancel clears the import")
            check(
                service.received.count == before && model.error == nil,
                "Cancelled import cannot launch or show a stale error")
        }
        do {
            let model = UsenetPlaybackCoordinator(), first = try file("old.nzb", "old"),
                next = try file("new.nzb", "new")
            let before = service.received.count
            model.importFile(first, makeRequest: request)
            model.importFile(next, makeRequest: request)
            try await settle { model.request != nil }
            check(
                service.received.count == before + 1 && service.received.last == Data("new".utf8),
                "Superseded import cannot prepare the old file")
            check(model.importedName == "new.nzb", "Latest filename is retained")
            model.finished()
        }
        do {
            service.videos = [
                UsenetVideo(id: 0, name: "One.mp4", extents: []),
                UsenetVideo(id: 1, name: "Two.mp4", extents: []),
            ]
            let model = UsenetPlaybackCoordinator()
            model.importFile(try file("multiple.nzb", "multiple"), makeRequest: request)
            try await settle { model.choices.count == 2 }
            check(!model.preparing && model.request == nil, "Multiple videos await selection")
            model.choose(service.videos[1]); model.finishChoosing()
            try await settle { model.request != nil }
            check(model.request?.title == "Two.mp4", "Video selection starts the chosen video")
            model.finished()
        }
        do {
            let model = UsenetPlaybackCoordinator(), url = try file("oversized.nzb", "")
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 16 * 1024 * 1024 + 1); try handle.close()
            model.importFile(url, makeRequest: request)
            try await settle { model.error != nil }
            check(
                model.error == UsenetError.invalidNZB.localizedDescription,
                "Copy imports retain the size bound")
            model.finished()
        }
        do {
            let model = UsenetPlaybackCoordinator(), indexer = IndexerServiceDouble()
            let release = NZBRelease(id: "one", title: "One")
            await model.prepareNZB(
                name: release.title, fetch: { try await indexer.nzb(release) }, makeRequest: request)
            check(
                model.error == UsenetError.providerRequired.localizedDescription,
                "Missing provider error remains visible")
            check(indexer.client.calls == 0, "Missing provider cannot spend an indexer NZB retrieval")
            model.finished()
            service.provider = UsenetProvider(
                host: "news.example.test", username: "user", password: "password")
            service.videos = [UsenetVideo(id: 0, name: "Selected.mp4", extents: [])]
            await model.prepareNZB(
                name: release.title, fetch: { try await indexer.nzb(release) }, makeRequest: request)
            check(
                model.request?.title == "Selected.mp4",
                "Indexer NZB reaches the existing playback request factory")
            check(indexer.client.calls == 1, "Only selected release is retrieved once")
            check(
                service.received.last == Data("indexer bytes".utf8),
                "Indexer bytes reach the existing Usenet engine")
            model.finished()
            await model.prepareNZB(
                name: "Denied", fetch: { throw NZBFinderError.privileges }, makeRequest: request)
            check(
                model.error == NZBFinderError.privileges.localizedDescription,
                "Indexer failures remain readable")
            model.finished()
            indexer.enabled = false
            await model.prepareNZB(
                name: release.title, fetch: { try await indexer.nzb(release) }, makeRequest: request)
            check(indexer.client.calls == 1 && model.request == nil, "Disabled indexer cannot fetch an NZB")
            model.finished()
        }
        do {
            service.videos = [
                UsenetVideo(id: 0, name: "Show.S01E01.mp4", extents: []),
                UsenetVideo(id: 1, name: "Show.S01E02.mp4", extents: []),
                UsenetVideo(id: 2, name: "Show.S01E02.sample.mp4", extents: []),
            ]
            let model = UsenetPlaybackCoordinator(), indexer = IndexerServiceDouble()
            let target = UsenetEpisodeTarget(season: 1, episode: 2)
            let release = NZBRelease(id: "pack", title: "Show S01 {{filename-secret}}", isSeasonPack: true)
            await model.prepareNZB(
                name: release.title, episodeTarget: target, fetch: { try await indexer.nzb(release) },
                makeRequest: request)
            check(
                model.request?.title == "Show.S01E02.mp4",
                "Pack chooses requested episode and excludes samples")
            check(
                service.receivedPasswords == ["embedded-secret"] && service.receivedName == release.title,
                "Response password and original name reach parser without re-fetching NZB")
            check(indexer.client.calls == 1, "Pack retrieval is only once")
            model.finished()
            service.videos = [service.videos[0]]
            await model.prepareNZB(
                name: "Pack", episodeTarget: target, fetch: { NZBDownload(data: Data()) },
                makeRequest: request)
            check(
                model.request == nil && model.choices.count == 1,
                "Wrong episode cannot silently autoplay even with one candidate")
            model.finished()
            service.videos = [
                UsenetVideo(id: 0, name: "Show.S01E02.mp4", extents: []),
                UsenetVideo(id: 1, name: "Show.S01E02.mkv", extents: []),
            ]
            await model.prepareNZB(
                name: "Pack", episodeTarget: target, fetch: { NZBDownload(data: Data()) },
                makeRequest: request)
            check(model.request == nil && model.choices.count == 2, "Ambiguous episode requires selection")
            model.finished()
        }
        let labeled = NZBRelease(
            id: "pack", title: "Show.S01.COMPLETE.1080p", isSeasonPack: true, requiresPassword: true
        ).streamOption
        check(
            labeled.displayName == "Show.S01.COMPLETE.1080p",
            "Release name is preserved above pack and encryption labels")
        let regular = NZBRelease(id: "movie", title: "Movie.2020.1080p").streamOption
        check(regular.displayName == "Movie.2020.1080p", "Regular release name survives an empty description")
        print("Passed \(passed) Usenet import regression checks.")
    }
}
