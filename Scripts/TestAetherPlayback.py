"""Exercise the adapter's actual transport methods without an iOS media runtime."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
playback = root / "Vesper/Features/Playback"
controller = (playback / "AetherPlaybackController.swift").read_text()
methods = []
for name in ["togglePlayback", "pause", "setSpeed", "beginBoost", "endBoost", "applyPlaybackRate", "reportProgress"]:
    start = controller.index("    private func " + name + "(") if "    private func " + name + "(" in controller else controller.index("    func " + name + "(")
    body = controller.index("{", start)
    depth, end = 1, body + 1
    while depth:
        depth += (controller[end] == "{") - (controller[end] == "}")
        end += 1
    methods.append(controller[start:end])
tests = (root / "Tests/AetherPlaybackControlTests.swift").read_text().replace("// INSERT_ACTUAL_METHODS", "\n".join(methods))
with tempfile.TemporaryDirectory(prefix="vesper-aether-controls-") as directory:
    source, binary = Path(directory) / "Regression.swift", Path(directory) / "Regression"
    source.write_text(tests)
    subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(source),
                    str(playback / "PlaybackState.swift"), str(root / "Core/Sources/VesperCore/PlaybackTimeline.swift"), str(root / "Core/Sources/VesperCore/PlaybackProgressReporter.swift"),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
