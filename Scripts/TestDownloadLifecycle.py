"""Run the production download transactions with disk and transport fixtures on the host."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
manager = (root / "Vesper/Features/Downloads/DownloadManager.swift").read_text()

def block(source, marker):
    start = source.index(marker)
    start = source.rfind("\n", 0, start) + 1
    brace = source.index("{", start)
    end, depth = brace + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

methods = [block(manager, "func " + name + "(") for name in [
    "commit", "change", "progress", "matching", "paused", "pause", "resume", "finished", "failed",
    "fileURL", "protect", "unprotect", "remove", "acquire", "receiveRejection", "finishBackgroundEvents", "submit",
    "candidates", "localArtwork", "offlineMedia", "offlineEpisode", "linkSharedArtwork", "begin", "stopBackgroundDownloads",
]]
methods.append(block(manager, "func schedule<"))
methods.append(block(manager, "func drive(").replace("func drive(", "func runDrive("))
progress = "\n".join(line for line in (root / "Vesper/Features/Downloads/DownloadProgress.swift").read_text().splitlines() if not line.startswith("import "))
fixture = (root / "Tests/DownloadLifecycleTests.swift").read_text()
fixture = fixture.replace("// ACTUAL_PROGRESS", progress)
fixture += "\n" + "\n".join(line for line in (root / "Vesper/Features/Playback/StreamModels.swift").read_text().splitlines() if not line.startswith("import "))
fixture = fixture.replace("// ACTUAL_METHODS", "\n".join(methods))
# The harness exercises actual methods directly; UI command wrappers stay private in the app.
fixture = fixture.replace("URLSessionDownloadTask", "TaskDouble")
fixture = fixture.replace("private func ", "func ").replace("@discardableResult private func ", "@discardableResult func ")
# Verify.sh builds the shared Core and tests before running this transport adapter harness.
scratch = Path(os.environ.get("VESPER_TEST_SCRATCH", "/tmp/vesper-usenet-core"))
info = json.loads(subprocess.check_output(["swift", "-print-target-info"]))
triple = info["target"]["triple"]
build = scratch / triple / "debug"
if not (build / "Modules/VesperCore.swiftmodule").exists():
    architecture = triple.split("-")[0]
    candidates = [p.parent.parent for p in scratch.glob("*/debug/Modules/VesperCore.swiftmodule") if p.parent.parent.parent.name.startswith(architecture)]
    if candidates:
        build = candidates[0]
objects = list((build / "VesperCore.build").glob("*.o"))
if not objects:
    raise SystemExit("Run the Core tests before the download lifecycle checks.")
router = (root / "Vesper/Features/Downloads/DownloadPlaybackRouter.swift").read_text()
router = router[router.index("@MainActor @Observable final class DownloadPlaybackRouter"):router.index("struct DownloadPlaybackPresentation")]
routing = (root / "Tests/DownloadRoutingTests.swift").read_text().replace("// ACTUAL_ROUTER", router)
for marker, path in [("// ACTUAL_VIDEO", "Vesper/Features/Playback/StreamModels.swift"), ("// ACTUAL_REQUEST", "Vesper/Features/Playback/PlaybackRequest.swift")]:
    source = (root / path).read_text()
    routing = routing.replace(marker, "\n".join(line for line in source.splitlines() if not line.startswith("import ")))
presentation = (root / "Tests/DownloadPresentationTests.swift").read_text()
presentation += "\n" + "\n".join(line for line in (root / "Vesper/Features/Downloads/DownloadTransferPresentation.swift").read_text().splitlines() if not line.startswith("import "))
for source in [fixture, routing, presentation]:
    with tempfile.TemporaryDirectory(prefix="vesper-download-lifecycle-") as directory:
        swift, binary = Path(directory) / "Tests.swift", Path(directory) / "Tests"
        swift.write_text(source)
        subprocess.run(["swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                        "-I", str(build / "Modules"), str(swift), *map(str, objects), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=30)
