"""Small, fail-closed rate-transition patches for checksum-pinned AetherEngine 7.36.0."""
from pathlib import Path


PATCHES = [
    (
        "Sources/AetherEngine/Native/NativeAVPlayerHost.swift",
        """        if value != 0 { avPlayer.defaultRate = value }
        avPlayer.rate = value
""",
        """        if value != 0, avPlayer.defaultRate != value { avPlayer.defaultRate = value }
        // Finlay: an in-flight speed change should consume the existing buffer immediately.
        // Keep AVPlayer's normal waiting policy for startup, resume and genuine starvation.
        if value > 0, avPlayer.timeControlStatus == .playing,
           avPlayer.currentItem?.status == .readyToPlay {
            guard avPlayer.rate != value else { return }
            avPlayer.playImmediately(atRate: value)
        } else {
            avPlayer.rate = value
        }
""",
    ),
    (
        "Sources/AetherEngine/Audio/AudioOutput.swift",
        '''    func setRate(_ rate: Float) {
        let at = synchronizer.currentTime()
        EngineLog.emit("[AudioOutput] setRate \\(rate) at t=\\(String(format: "%.3f", timeline.sourceSeconds(forRenderer: at.seconds)))", category: .swPlayback)
        synchronizer.setRate(rate, time: at)
    }''',
        '''    func setRate(_ rate: Float) {
        guard synchronizer.rate != rate else { return }
        // Finlay: changing speed must not reset the shared audio/video clock to a stale
        // snapshot. Invalid time preserves its advancing position, including during logging.
        synchronizer.setRate(rate, time: .invalid)
        let at = synchronizer.currentTime()
        EngineLog.emit("[AudioOutput] setRate \\(rate) at t=\\(String(format: "%.3f", timeline.sourceSeconds(forRenderer: at.seconds)))", category: .swPlayback)
    }''',
    ),
]


def apply_rate_patches(destination: Path):
    # Validate every replacement before writing any. A dependency update must be reviewed,
    # not silently patched with offsets or an approximate match. Cache hits are idempotent.
    pending = []
    for relative, before, after in PATCHES:
        path = destination / relative
        contents = path.read_text()
        if contents.count(after) == 1 and before not in contents:
            continue
        if contents.count(before) != 1 or after in contents:
            raise RuntimeError(f"Aether rate patch no longer matches {relative}; review the pinned source.")
        pending.append((path, contents.replace(before, after, 1)))
    for path, contents in pending:
        path.write_text(contents)
