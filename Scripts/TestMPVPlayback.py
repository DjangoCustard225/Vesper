"""Exercise the actual controller with a deterministic engine/audio-session double.

Runs on Linux or macOS without an iOS runtime. Does not simulate decoding/rendering.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
playback = root / "Vesper/Features/Playback"
reporter = (root / "Core/Sources/VesperCore/TraktPlaybackReporter.swift").read_text().split("/// Serializes delivery")[0] + "\n#endif\n"
action = next(line for line in (root / "Core/Sources/VesperCore/TraktModels.swift").read_text().splitlines() if line.startswith("public enum TraktScrobbleAction"))
controller = (playback / "MPVPlaybackController.swift").read_text()
controller = "\n".join(line for line in controller.splitlines() if not line.startswith("import "))
with tempfile.TemporaryDirectory(prefix="vesper-mpv-tests-") as directory:
    source = Path(directory) / "Regression.swift"
    binary = Path(directory) / "Regression"
    source.write_text(action + "\n" + reporter + "\n" + (root / "Tests/MPVPlaybackMocks.swift").read_text() + "\n" + controller + "\n" + (root / "Tests/MPVPlaybackControllerTests.swift").read_text())
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(source), str(playback / "PlaybackState.swift"), str(root / "Core/Sources/VesperCore/PlaybackTimeline.swift"), str(root / "Core/Sources/VesperCore/PlaybackProgressReporter.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
