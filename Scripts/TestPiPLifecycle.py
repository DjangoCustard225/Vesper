"""Exercise actual AVKit handoff callbacks with deterministic platform doubles.

The system animation and video output still need checking on a physical iOS device.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "Vesper/Features/Playback/NativePictureInPicture.swift").read_text()
starts = [match.start() for match in re.finditer(r"^    (?:private )?func\b", source, re.MULTILINE)]


def declaration(marker):
    match = source.index(marker)
    start = max(position for position in starts if position <= match)
    body = source.index("{", match)
    end, depth = body + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


markers = [
    "func enteredBackground(", "func enteredForeground(", "func invalidate(",
    "func cancelBackgroundHandoff(", "func completeRestoration(", "func finishInvalidation(",
    "func pictureInPictureControllerWillStartPictureInPicture(",
    "func pictureInPictureControllerDidStartPictureInPicture(",
    "func pictureInPictureControllerWillStopPictureInPicture(",
    "func pictureInPictureControllerDidStopPictureInPicture(",
    "failedToStartPictureInPictureWithError error:",
    "restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion:",
]
methods = "\n".join(declaration(marker) for marker in markers)
fixture = (root / "Tests/PiPLifecycleTests.swift").read_text().replace("// ACTUAL_METHODS", methods)
with tempfile.TemporaryDirectory(prefix="vesper-pip-tests-") as directory:
    swift, binary = Path(directory) / "Tests.swift", Path(directory) / "Tests"
    swift.write_text(fixture)
    subprocess.run([
        "swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library", str(swift),
        str(root / "Core/Sources/VesperCore/AutomaticPictureInPicture.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
