"""Test the actual cancellable final copy and repair algebra without a UIKit runtime."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "Vesper/Features/Usenet/UsenetDownloadTransfer.swift").read_text()
start = source.index("    private nonisolated static func copy(")
brace = source.index("{", start)
end, depth = brace + 1, 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
method = source[start:end].replace("private nonisolated static", "static")
fixture = (root / "Tests/DownloadPostprocessingTests.swift").read_text().replace("// ACTUAL_COPY", method)
scratch = Path(os.environ.get("VESPER_TEST_SCRATCH", "/tmp/vesper-usenet-core"))
triple = json.loads(subprocess.check_output(["swift", "-print-target-info"]))["target"]["triple"]
build = scratch / triple / "debug"
if not (build / "Modules/VesperCore.swiftmodule").exists():
    candidates = [p.parent.parent for p in scratch.glob("*/debug/Modules/VesperCore.swiftmodule")
                  if p.parent.parent.parent.name.startswith(triple.split("-")[0])]
    if candidates:
        build = candidates[0]
objects = list((build / "VesperCore.build").glob("*.o"))
if not objects:
    raise SystemExit("Run Core tests before postprocessing checks.")
with tempfile.TemporaryDirectory(prefix="vesper-postprocessing-tests-") as directory:
    swift, binary = Path(directory) / "Tests.swift", Path(directory) / "Tests"
    swift.write_text(fixture)
    subprocess.run(["swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                    "-I", str(build / "Modules"), str(swift),
                    str(root / "Packages/PAR2Kit/Sources/PAR2Kit/GaloisField16.swift"),
                    str(root / "Packages/PAR2Kit/Sources/PAR2Kit/ReedSolomon.swift"),
                    *map(str, objects), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
