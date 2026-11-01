import Foundation

let MPMediaItemPropertyTitle = "title", MPMediaItemPropertyArtist = "artist",
    MPMediaItemPropertyArtwork = "artwork"
let MPMediaItemPropertyPlaybackDuration = "duration", MPNowPlayingInfoPropertyElapsedPlaybackTime = "elapsed"
let MPNowPlayingInfoPropertyPlaybackRate = "rate", MPNowPlayingInfoPropertyDefaultPlaybackRate = "defaultRate"
let MPNowPlayingInfoPropertyMediaType = "type", MPNowPlayingInfoPropertyIsLiveStream = "live"
enum MPNowPlayingInfoMediaType: Int { case video = 2 }
enum MPRemoteCommandHandlerStatus { case success, commandFailed }
class MPRemoteCommandEvent: @unchecked Sendable {}
final class MPSkipIntervalCommandEvent: MPRemoteCommandEvent, @unchecked Sendable {
    let interval: Double
    init(_ interval: Double) { self.interval = interval }
}
final class MPChangePlaybackPositionCommandEvent: MPRemoteCommandEvent, @unchecked Sendable {
    let positionTime: Double
    init(_ seconds: Double) { positionTime = seconds }
}
@MainActor final class MPRemoteCommand {
    var isEnabled = false
    var preferredIntervals: [Int] = []
    var handlers: [UUID: @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus] = [:]
    func addTarget(handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) -> Any
    {
        let id = UUID(); handlers[id] = handler; return id
    }
    func removeTarget(_ target: Any) { handlers[target as! UUID] = nil }
    @discardableResult func send(_ event: MPRemoteCommandEvent = MPRemoteCommandEvent())
        -> MPRemoteCommandHandlerStatus
    {
        guard isEnabled else { return .commandFailed }
        return handlers.values.first?(event) ?? .commandFailed
    }
}
@MainActor final class MPRemoteCommandCenter {
    private static let sharedValue = MPRemoteCommandCenter()
    static func shared() -> MPRemoteCommandCenter { sharedValue }
    let playCommand = MPRemoteCommand(), pauseCommand = MPRemoteCommand(),
        togglePlayPauseCommand = MPRemoteCommand()
    let skipForwardCommand = MPRemoteCommand(), skipBackwardCommand = MPRemoteCommand(),
        changePlaybackPositionCommand = MPRemoteCommand()
    let nextTrackCommand = MPRemoteCommand(), previousTrackCommand = MPRemoteCommand(),
        stopCommand = MPRemoteCommand()
    let changePlaybackRateCommand = MPRemoteCommand()
}
@MainActor final class MPNowPlayingInfoCenter {
    private static let sharedValue = MPNowPlayingInfoCenter()
    static func `default`() -> MPNowPlayingInfoCenter { sharedValue }
    var nowPlayingInfo: [String: Any]?
}
final class PlayerDouble {}
@MainActor final class MPNowPlayingSession {
    let players: [PlayerDouble]
    let remoteCommandCenter = MPRemoteCommandCenter()
    let nowPlayingInfoCenter = MPNowPlayingInfoCenter()
    var automaticallyPublishesNowPlayingInfo = false
    var activations = 0
    init(_ player: PlayerDouble) { players = [player] }
    func becomeActiveIfPossible(completion: ((Bool) -> Void)?) { activations += 1; completion?(true) }
}
@MainActor final class EngineDouble {
    var videoNowPlayingSession: MPNowPlayingSession?
    var audioNowPlayingSession: MPNowPlayingSession?
    var currentAVPlayer: PlayerDouble?
    var videoInfo: [String: Any] = [:], audioInfo: [String: Any] = [:]
    func setVideoNowPlayingInfo(_ info: [String: Any]) { videoInfo = info }
    func setAudioNowPlayingInfo(_ info: [String: Any]) { audioInfo = info }
}
@MainActor final class AetherPlaybackController {
    var engine: EngineDouble? = EngineDouble()
    var error: String?
    var canAcceptRemoteCommands = true
    var isPlaying = true, isBuffering = false, hasEnded = false, isBoosting = false
    var speed: Float = 1
    var timeline = PlaybackTimeline(elapsed: 20, duration: 100, isSeekable: true)
    var toggles = 0, pauses = 0
    var skips: [Double] = [], seeks: [Double] = []
    func togglePlayback() { toggles += 1; isPlaying.toggle() }
    func pause() { pauses += 1; isPlaying = false }
    func seek(fraction: Double) { seeks.append(fraction) }
    func skip(seconds: Double) { skips.append(seconds) }
}
final class UIImage: @unchecked Sendable { var size: CGSize { CGSize(width: 200, height: 300) } }
final class MPMediaItemArtwork {
    let request: @Sendable (CGSize) -> UIImage
    init(boundsSize: CGSize, requestHandler: @escaping @Sendable (CGSize) -> UIImage) {
        request = requestHandler
    }
}
struct ArtworkDecodeSize { init(width: Double, height: Double, scale: Double) {} }
enum ArtworkPriority { case prefetch }
actor ArtworkPipeline {
    static let shared = ArtworkPipeline()
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func suspendNext() { suspended = true }
    func release() { suspended = false; continuation?.resume(); continuation = nil }
    func image(for url: URL, size: ArtworkDecodeSize, priority: ArtworkPriority) async throws -> UIImage {
        if suspended { await withCheckedContinuation { continuation = $0 } }
        await Task.yield()
        return UIImage()
    }
}

// ACTUAL_IMPLEMENTATION

@main @MainActor struct Regression {
    static func flush() async { for _ in 0..<15 { await Task.yield() } }
    static func main() async {
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); passed += 1
        }
        let metadata = PlaybackMediaInfo(title: "Show", subtitle: "S2 · E3 · Episode")
        do {
            let owner = AetherPlaybackController(), player = PlayerDouble()
            let session = MPNowPlayingSession(player)
            owner.engine?.currentAVPlayer = player
            owner.engine?.videoNowPlayingSession = session
            let now = SystemNowPlaying(owner: owner, media: metadata, isLive: false)
            now.update()
            let commands = session.remoteCommandCenter
            check(session.activations == 1, "The native session must be activated once")
            check(
                owner.engine?.videoInfo[MPMediaItemPropertyTitle] as? String == "Show",
                "Publish the content title")
            check(
                owner.engine?.videoInfo[MPMediaItemPropertyArtist] as? String == metadata.subtitle,
                "Publish episode identity")
            check(
                owner.engine?.videoInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil,
                "AVPlayer owns native timing")
            commands.playCommand.send(); await flush()
            check(owner.toggles == 0, "Remote play must be idempotent while playing")
            commands.pauseCommand.send(); await flush()
            check(!owner.isPlaying && owner.pauses == 1, "Remote pause reaches the player")
            commands.playCommand.send(); await flush()
            check(owner.isPlaying && owner.toggles == 1, "Remote play resumes through existing controls")
            commands.skipForwardCommand.send(MPSkipIntervalCommandEvent(10))
            commands.skipBackwardCommand.send(MPSkipIntervalCommandEvent(10))
            commands.changePlaybackPositionCommand.send(MPChangePlaybackPositionCommandEvent(55))
            await flush()
            check(Set(owner.skips) == Set([10, -10]), "Remote skips use the requested directions")
            check(owner.seeks == [0.55], "Absolute system seeking maps to the playback timeline")
            check(commands.skipForwardCommand.preferredIntervals == [10], "Advertise ten-second skips")
            check(
                commands.changePlaybackPositionCommand.send(MPChangePlaybackPositionCommandEvent(.nan))
                    == .commandFailed,
                "Reject non-finite seeks")
            check(
                commands.skipForwardCommand.send(MPSkipIntervalCommandEvent(-1)) == .commandFailed,
                "Reject invalid intervals")
            check(
                !commands.nextTrackCommand.isEnabled,
                "Do not open a source picker from a background next-track command")
            now.update()
            check(
                commands.playCommand.handlers.count == 1 && session.activations == 1,
                "Clock updates must not duplicate handlers or activation")
            owner.timeline = PlaybackTimeline(elapsed: 20, duration: 0, isSeekable: false)
            now.update()
            check(
                !commands.changePlaybackPositionCommand.isEnabled && !commands.skipForwardCommand.isEnabled,
                "Unseekable sources disable seeking")
            owner.isBuffering = true; now.update()
            check(commands.pauseCommand.isEnabled, "Pause must remain available during buffering")
            let stale = commands.pauseCommand.handlers.values.first!
            now.invalidate()
            _ = stale(MPRemoteCommandEvent()); await flush()
            check(owner.pauses == 1, "Retired callbacks cannot control playback")
            check(
                commands.playCommand.handlers.isEmpty && !session.automaticallyPublishesNowPlayingInfo,
                "Cleanup removes handlers and stops publication")
            check(owner.engine?.videoInfo.isEmpty == true, "Closing clears the staged identity")
        }
        do {
            let owner = AetherPlaybackController()
            let now = SystemNowPlaying(owner: owner, media: metadata, isLive: false)
            now.update()
            let center = MPNowPlayingInfoCenter.default()
            check(
                center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 20,
                "Software playback publishes elapsed time")
            check(
                center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double == 100,
                "Software playback publishes duration")
            owner.isBoosting = true; now.update()
            check(
                center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Float == 2,
                "Hold-to-2x updates the system rate")
            owner.isPlaying = false; now.update()
            check(
                center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Int == 0,
                "Paused software playback stops the system clock")
            owner.isPlaying = true; owner.isBoosting = false
            let next = AetherPlaybackController()
            let replacement = SystemNowPlaying(
                owner: next, media: PlaybackMediaInfo(title: "Next", subtitle: nil), isLive: false)
            replacement.update()
            now.update(); now.invalidate()
            check(
                center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Next",
                "An old fallback cannot overwrite or clear a newer player")
            let command = MPRemoteCommandCenter.shared().pauseCommand
            check(command.handlers.count == 1, "Old fallback cleanup leaves only the new handler")
            command.send(); await flush()
            check(next.pauses == 1 && owner.pauses == 0, "The replacement alone handles system commands")
            replacement.invalidate()
            check(
                center.nowPlayingInfo == nil && command.handlers.isEmpty,
                "Closing the final fallback clears the media card")
        }
        do {
            let owner = AetherPlaybackController()
            let now = SystemNowPlaying(owner: owner, media: metadata, isLive: true)
            now.update()
            check(
                !MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled,
                "Live streams do not expose VOD seeking")
            check(
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] == nil,
                "Live metadata omits a VOD duration")
            let player = PlayerDouble(), native = MPNowPlayingSession(PlayerDouble())
            owner.engine?.videoNowPlayingSession = native
            owner.engine?.currentAVPlayer = player
            now.update()
            check(native.activations == 0, "Do not bind a session belonging to a retired AVPlayer")
            let active = MPNowPlayingSession(player)
            owner.engine?.audioNowPlayingSession = active
            now.update()
            check(
                active.activations == 1 && active.remoteCommandCenter.playCommand.handlers.count == 1,
                "A route change binds the matching audio session")
            check(
                MPNowPlayingInfoCenter.default().nowPlayingInfo == nil,
                "Switching to native publication clears the fallback card")
            check(
                MPRemoteCommandCenter.shared().playCommand.handlers.isEmpty,
                "Route changes detach fallback handlers")
            now.invalidate()
        }
        do {
            let owner = AetherPlaybackController()
            let media = PlaybackMediaInfo(
                title: "Poster", subtitle: nil, artworkURL: URL(string: "https://images.example/poster"))
            let now = SystemNowPlaying(owner: owner, media: media, isLive: false)
            now.update()
            for _ in 0..<500 {
                if owner.engine?.videoInfo[MPMediaItemPropertyArtwork] != nil { break }
                try? await Task.sleep(for: .milliseconds(2))
            }
            check(
                owner.engine?.videoInfo[MPMediaItemPropertyArtwork] != nil,
                "Artwork arrives asynchronously without delaying playback")
            now.invalidate()
            await flush()
            check(
                MPNowPlayingInfoCenter.default().nowPlayingInfo == nil,
                "Artwork cannot republish a retired session")
        }
        do {
            await ArtworkPipeline.shared.suspendNext()
            let owner = AetherPlaybackController()
            let now = SystemNowPlaying(
                owner: owner,
                media: PlaybackMediaInfo(
                    title: "Late poster", subtitle: nil,
                    artworkURL: URL(string: "https://images.example/late")
                ), isLive: false)
            now.update()
            for _ in 0..<500 {
                if await ArtworkPipeline.shared.waiting { break }
                try? await Task.sleep(for: .milliseconds(2))
            }
            now.invalidate()
            await ArtworkPipeline.shared.release()
            await flush()
            check(
                owner.engine?.videoInfo.isEmpty == true, "Late artwork cannot restore cleared engine metadata"
            )
            check(
                MPNowPlayingInfoCenter.default().nowPlayingInfo == nil,
                "Late artwork cannot restore a retired system card")
        }
        print("Passed \(passed) system Now Playing regression checks.")
    }
}
