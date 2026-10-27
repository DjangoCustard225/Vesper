"""Verify reproducible vendor patches and rate commands with deterministic AVFoundation doubles."""
from pathlib import Path
import subprocess
import tempfile

from AetherRateTransitions import PATCHES, apply_rate_patches

ROOT = Path(__file__).resolve().parent.parent

with tempfile.TemporaryDirectory(prefix="vesper-aether-rate-") as directory:
    staging = Path(directory)
    for relative, before, _ in PATCHES:
        target = staging / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(before)
    apply_rate_patches(staging)
    expected = {relative: (staging / relative).read_text() for relative, _, _ in PATCHES}
    apply_rate_patches(staging)
    assert all((staging / relative).read_text() == value for relative, value in expected.items())
    # A changed/ambiguous upstream source must fail before altering any other file.
    first, second = [staging / patch[0] for patch in PATCHES]
    first.write_text(PATCHES[0][1])
    second.write_text("unexpected upstream implementation")
    try:
        apply_rate_patches(staging)
        raise AssertionError("Unexpected source was accepted")
    except RuntimeError:
        assert first.read_text() == PATCHES[0][1]
    first.write_text(PATCHES[0][1] * 2)
    try:
        apply_rate_patches(staging)
        raise AssertionError("Ambiguous source was accepted")
    except RuntimeError:
        pass
    source = (ROOT / "Tests/AetherRateTransitionTests.swift").read_text()
    source = source.replace("// INSERT_NATIVE_RATE_BODY", PATCHES[0][2])
    source = source.replace("// INSERT_SOFTWARE_RATE_METHOD", PATCHES[1][2])
    swift, binary = staging / "Regression.swift", staging / "Regression"
    swift.write_text(source)
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("Passed 3 Aether patch reproducibility checks.")
