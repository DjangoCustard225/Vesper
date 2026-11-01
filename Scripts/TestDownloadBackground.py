"""Exercise the actual background coordinator with a deterministic native scheduler adapter."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
scratch = Path(os.environ.get("VESPER_TEST_SCRATCH", "/tmp/vesper-usenet-core"))
triple = json.loads(subprocess.check_output(["swift", "-print-target-info"]))["target"]["triple"]
build = scratch / triple / "debug"
if not (build / "Modules/VesperCore.swiftmodule").exists():
    architecture = triple.split("-")[0]
    candidates = [p.parent.parent for p in scratch.glob("*/debug/Modules/VesperCore.swiftmodule")
                  if p.parent.parent.parent.name.startswith(architecture)]
    if candidates:
        build = candidates[0]
objects = list((build / "VesperCore.build").glob("*.o"))
if not objects:
    raise SystemExit("Run the Core tests before background lifecycle checks.")
with tempfile.TemporaryDirectory(prefix="vesper-background-tests-") as directory:
    binary = Path(directory) / "Tests"
    subprocess.run(["swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                    "-I", str(build / "Modules"), str(root / "Tests/DownloadBackgroundTests.swift"),
                    str(root / "Vesper/Features/Downloads/DownloadBackgroundCoordinator.swift"),
                    *map(str, objects), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
