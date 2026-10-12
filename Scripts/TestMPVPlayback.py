"""Exercise the actual controller with a deterministic engine/audio-session double.

Runs on Linux or macOS without an iOS runtime. Does not simulate decoding/rendering.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
playback = root / "Vesper/Features/Playback"
controller = (playback / "MPVPlaybackController.swift").read_text()
controller = "\n".join(line for line in controller.splitlines() if not line.startswith("import "))
with tempfile.TemporaryDirectory(prefix="vesper-mpv-tests-") as directory:
    source = Path(directory) / "Regression.swift"
    binary = Path(directory) / "Regression"
    source.write_text((root / "Tests/MPVPlaybackMocks.swift").read_text() + "\n" + controller + "\n" + (root / "Tests/MPVPlaybackControllerTests.swift").read_text())
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(source), str(playback / "PlaybackState.swift"), str(root / "Core/Sources/VesperCore/PlaybackTimeline.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
