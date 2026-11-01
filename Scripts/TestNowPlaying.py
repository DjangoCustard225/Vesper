"""Exercise the production Now Playing bridge with deterministic MediaPlayer doubles."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "Vesper/Features/Playback/SystemNowPlaying.swift").read_text()
implementation = "\n".join(line for line in source.splitlines() if not line.startswith("import "))
fixture = (root / "Tests/NowPlayingTests.swift").read_text().replace("// ACTUAL_IMPLEMENTATION", implementation)
with tempfile.TemporaryDirectory(prefix="vesper-now-playing-") as directory:
    swift, binary = Path(directory) / "Tests.swift", Path(directory) / "Tests"
    swift.write_text(fixture)
    subprocess.run([
        "swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library", str(swift),
        str(root / "Vesper/Features/Playback/PlaybackState.swift"),
        str(root / "Core/Sources/VesperCore/PlaybackTimeline.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
