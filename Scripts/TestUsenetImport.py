"""Exercise the actual import coordinator and bounded file reader without a UIKit runtime."""
from pathlib import Path
import os
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "Vesper/Features/Usenet/UsenetPlaybackCoordinator.swift").read_text()
coordinator = source[source.index("@MainActor @Observable final class"):source.index("private struct UsenetPlaybackPresentation")]
source = (root / "Vesper/Features/Usenet/UsenetService.swift").read_text()
start = source.index("    nonisolated static func importFile(")
body = source.index("{", start)
end, depth = body + 1, 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
reader = source[start:end]
source = (root / "Vesper/Features/Usenet/NZBFinderService.swift").read_text()
start = source.index("    func nzb(")
body = source.index("{", start)
end, depth = body + 1, 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
retrieval = source[start:end]
display = (root / "Vesper/Features/Playback/StreamModels.swift").read_text()
display = display[display.index("extension StreamOption {"):]
fixture = (root / "Tests/UsenetImportTests.swift").read_text().replace("// ACTUAL_DISPLAY_NAME", display).replace("// ACTUAL_COORDINATOR", coordinator).replace("// ACTUAL_READER", reader).replace("// ACTUAL_RETRIEVAL", retrieval)
triple = json.loads(subprocess.check_output(["swift", "-print-target-info"]))["target"]["triple"]
def build_path(variable, fallback, module):
    scratch = Path(os.environ.get(variable, fallback))
    build = scratch / triple / "debug"
    if not (build / f"Modules/{module}.swiftmodule").exists():
        matches = [p.parent.parent for p in scratch.glob(f"*/debug/Modules/{module}.swiftmodule") if p.parent.parent.parent.name.startswith(triple.split("-")[0])]
        if not matches:
            raise SystemExit(f"Run the {module} tests before import regression checks.")
        build = matches[0]
    return build
core = build_path("VESPER_TEST_SCRATCH", "/tmp/vesper-usenet-core", "VesperCore")
engine = build_path("VESPER_USENET_TEST_SCRATCH", "/tmp/vesper-usenet-engine-tests", "UsenetEngine")
with tempfile.TemporaryDirectory(prefix="vesper-usenet-import-") as directory:
    swift, binary = Path(directory) / "Tests.swift", Path(directory) / "Tests"
    swift.write_text(fixture)
    subprocess.run([
        "swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
        "-Xcc", "-fmodule-map-file=" + str(engine / "CUsenetCrypto.build/module.modulemap"),
        "-I", str(root / "Packages/UsenetEngine/Sources/CUsenetCrypto/include"),
        "-I", str(core / "Modules"), "-I", str(engine / "Modules"), str(swift),
        *map(str, sorted((core / "VesperCore.build").glob("*.o"))),
        *map(str, sorted((engine / "UsenetEngine.build").glob("*.o"))),
        *map(str, sorted((engine / "CUsenetCrypto.build").glob("*.o"))),
        *(["-l:libcrypto.so.3"] if os.uname().sysname == "Linux" else []),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
