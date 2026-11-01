import Foundation
import MediaPlayer
import UIKit
import VesperCore

struct PlaybackMediaInfo {
    let title: String
    let subtitle: String?
    var artworkURL: URL? = nil
}

/// Owns metadata and remote-command handlers for one playback lifetime.
/// AVPlayer publishes its own timing; software playback uses the app's timeline.
@MainActor
final class SystemNowPlaying {
    private static var fallbackOwner: UUID?
    private let id = UUID()
    private weak var owner: AetherPlaybackController?
    private var session: MPNowPlayingSession?
    private var commands: MPRemoteCommandCenter?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var bindingID = UUID()
    private var usesFallback = false
    private var invalidated = false
    private var artworkTask: Task<Void, Never>?
    private var info: [String: Any]

    init(owner: AetherPlaybackController, media: PlaybackMediaInfo, isLive: Bool) {
        self.owner = owner
        info = [
            MPMediaItemPropertyTitle: media.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if let subtitle = media.subtitle, !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        publishIdentity()
        if let url = media.artworkURL {
            artworkTask = Task { [weak self] in
                guard
                    let image = try? await ArtworkPipeline.shared.image(
                        for: url, size: ArtworkDecodeSize(width: 512, height: 768, scale: 1),
                        priority: .prefetch
                    ), !Task.isCancelled, let self, !self.invalidated
                else { return }
                let prepared = NowPlayingArtworkImage(image)
                self.info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in
                    prepared.image
                }
                self.publishIdentity()
            }
        }
    }

    isolated deinit { invalidate() }

    func update() {
        guard !invalidated, let owner, let engine = owner.engine else { return }
        let native = [engine.videoNowPlayingSession, engine.audioNowPlayingSession].compactMap { $0 }.first {
            session in session.players.contains { $0 === engine.currentAVPlayer }
        }
        let fallback = native == nil
        if usesFallback, fallback, Self.fallbackOwner != id { return }
        if commands == nil || session !== native || usesFallback != fallback {
            unbind()
            session = native
            usesFallback = fallback
            if fallback { Self.fallbackOwner = id }
            commands = native?.remoteCommandCenter ?? MPRemoteCommandCenter.shared()
            bind()
            native?.automaticallyPublishesNowPlayingInfo = true
            native?.becomeActiveIfPossible(completion: nil)
            publishIdentity()
        }
        let ready = owner.canAcceptRemoteCommands
        commands?.playCommand.isEnabled = ready
        commands?.pauseCommand.isEnabled = ready
        commands?.togglePlayPauseCommand.isEnabled = ready
        let seekable =
            ready && owner.timeline.isSeekable && info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool != true
        commands?.skipForwardCommand.isEnabled = seekable
        commands?.skipBackwardCommand.isEnabled = seekable
        commands?.changePlaybackPositionCommand.isEnabled = seekable
        if usesFallback, Self.fallbackOwner == id {
            var values = info
            values[MPNowPlayingInfoPropertyElapsedPlaybackTime] = owner.timeline.elapsed
            values[MPNowPlayingInfoPropertyPlaybackRate] =
                owner.isPlaying ? (owner.isBoosting ? PlaybackSpeed.boost : owner.speed) : 0
            values[MPNowPlayingInfoPropertyDefaultPlaybackRate] = owner.speed
            if owner.timeline.duration > 0, values[MPNowPlayingInfoPropertyIsLiveStream] as? Bool != true {
                values[MPMediaItemPropertyPlaybackDuration] = owner.timeline.duration
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = values
        }
    }

    private func publishIdentity() {
        guard !invalidated, let engine = owner?.engine else { return }
        engine.setVideoNowPlayingInfo(info)
        engine.setAudioNowPlayingInfo(info)
        if usesFallback { update() }
    }

    private enum Command: Sendable { case play, pause, toggle, skip(Double), seek(Double) }

    private func bind() {
        guard let commands else { return }
        register(commands.playCommand) { _ in .play }
        register(commands.pauseCommand) { _ in .pause }
        register(commands.togglePlayPauseCommand) { _ in .toggle }
        commands.skipForwardCommand.preferredIntervals = [10]
        commands.skipBackwardCommand.preferredIntervals = [10]
        register(commands.skipForwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent, event.interval.isFinite,
                event.interval > 0
            else {
                return nil
            }
            return .skip(event.interval)
        }
        register(commands.skipBackwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent, event.interval.isFinite,
                event.interval > 0
            else {
                return nil
            }
            return .skip(-event.interval)
        }
        register(commands.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent, event.positionTime.isFinite
            else { return nil }
            return .seek(event.positionTime)
        }
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        commands.stopCommand.isEnabled = false
        commands.changePlaybackRateCommand.isEnabled = false
    }

    private func register(
        _ remote: MPRemoteCommand, decode: @escaping @Sendable (MPRemoteCommandEvent) -> Command?
    ) {
        let binding = bindingID
        let target = remote.addTarget { [weak self] event in
            guard let self, let command = decode(event) else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, self.bindingID == binding, !self.invalidated,
                    !self.usesFallback || Self.fallbackOwner == self.id
                else { return }
                self.perform(command)
            }
            return .success
        }
        targets.append((remote, target))
    }

    private func perform(_ command: Command) {
        guard let owner, owner.canAcceptRemoteCommands else { return }
        switch command {
        case .play: if !owner.isPlaying { owner.togglePlayback() }
        case .pause: owner.pause()
        case .toggle: owner.togglePlayback()
        case .skip(let seconds):
            guard owner.timeline.isSeekable, info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool != true
            else { return }
            owner.skip(seconds: seconds)
        case .seek(let seconds):
            guard owner.timeline.isSeekable, info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool != true
            else { return }
            owner.seek(fraction: seconds / owner.timeline.duration)
        }
        update()
    }

    private func unbind() {
        bindingID = UUID()
        targets.forEach { $0.0.removeTarget($0.1) }
        targets = []
        if let session {
            session.automaticallyPublishesNowPlayingInfo = false
            session.nowPlayingInfoCenter.nowPlayingInfo = nil
        } else if usesFallback, Self.fallbackOwner == id {
            Self.fallbackOwner = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
        session = nil
        commands = nil
        usesFallback = false
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        artworkTask?.cancel()
        artworkTask = nil
        unbind()
        owner?.engine?.setVideoNowPlayingInfo([:])
        owner?.engine?.setAudioNowPlayingInfo([:])
        owner = nil
    }
}

/// The pipeline prepares pixels before publication; MediaPlayer may request them off the main actor.
private final class NowPlayingArtworkImage: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}
