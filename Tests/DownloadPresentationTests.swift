import Foundation
import VesperCore

@main struct DownloadPresentationRegression {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        let source = try JSONDecoder().decode(
            StreamSource.self,
            from: Data(
                #"{"url":"https://example.test/video.mkv","behaviorHints":{"filename":"Movie.mkv"}}"#.utf8))
        func record(_ phase: DownloadPhase) -> DownloadRecord {
            var record = DownloadRecord(
                media: MediaItem(id: "tt1", type: "movie", name: "Movie", poster: nil),
                videoID: "tt1", subtitle: nil, episode: nil, source: source, providerID: nil,
                fetchedAt: Date())
            record.phase = phase; return record
        }
        var active = record(.downloading)
        let queued = record(.queued), completed = record(.completed)
        check(
            DownloadTransferPresentation.preferredID(in: [queued, completed, active], keeping: nil)
                == active.id,
            "Initially feature the actively downloading episode")
        active.phase = .completed
        check(
            DownloadTransferPresentation.preferredID(in: [queued, active], keeping: active.id) == active.id,
            "Completion cannot silently switch the selected episode")
        check(
            DownloadTransferPresentation.preferredID(in: [queued], keeping: active.id) == queued.id,
            "Removing the selection falls back to a remaining download")
        check(
            DownloadTransferPresentation.preferredID(in: [], keeping: active.id) == nil,
            "An empty title has no selection")
        for (phase, action) in [
            (DownloadPhase.downloading, DownloadTransferPresentation.Action.pause),
            (.preparing, .pause), (.queued, .pause), (.paused, .resume), (.failed, .retry),
            (.completed, .play),
        ] {
            check(
                DownloadTransferPresentation(record: record(phase)).action == action,
                "Correct native action for \(phase)")
        }
        var input = record(.paused); input.usenetNeedsPassword = true
        check(
            DownloadTransferPresentation(record: input).action == .enterPassword,
            "Password prompts take priority over resume")
        input.usenetNeedsPassword = nil; input.usenetFiles = ["episode.mkv"]
        check(
            DownloadTransferPresentation(record: input).action == .chooseVideo,
            "File selection takes priority over resume")
        let presentation = DownloadTransferPresentation(record: record(.downloading))
        check(
            presentation.fraction(bytes: 0, total: nil, work: nil) == nil, "Unknown sizes stay indeterminate")
        check(
            presentation.fraction(bytes: 500, total: 1000, work: nil) == 0.45,
            "Transfer progress reserves finishing work")
        check(
            (presentation.fraction(bytes: 1000, total: 1000, work: .init(.saving, fraction: 1)) ?? 1) < 1,
            "Finishing cannot show completed progress")
        check(
            DownloadTransferPresentation(record: completed).fraction(bytes: 1, total: nil, work: nil) == 1,
            "Only completed records show full progress")
        check(presentation.filename == "Movie.mkv", "Details retain the complete source filename")
        let waiting = DownloadTransferPresentation(record: queued)
        check(
            waiting.status(networkAvailable: false, canTransfer: false, work: nil)
                == "Waiting for connection",
            "Offline status does not claim to be downloading")
        check(
            waiting.status(networkAvailable: true, canTransfer: false, work: nil) == "Waiting for Wi-Fi",
            "Cellular restrictions remain visible")
        check(
            presentation.status(networkAvailable: true, canTransfer: true, work: .init(.repairing))
                == "Repairing files…",
            "Finishing stages use their actual status")
        print("Passed \(checks) download presentation checks.")
    }
}
