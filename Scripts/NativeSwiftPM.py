"""Optional xtool adapter for restricted Linux environments without SwiftBuild IPC.

xtool still performs app planning, resources, Info.plist assembly and IPA packaging.
Only SwiftPM compilation uses its native build system instead of SwiftBuild.
"""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

args = sys.argv[2:]
result = []
i = 0
while i < len(args):
    arg = args[i]
    if arg == "--build-system":
        result += [arg, "native"]
        i += 2
    elif arg in ["--triple", "--toolset"]:
        i += 2
    else:
        result.append(arg)
        i += 1
cache = Path(os.environ.get("XDG_CACHE_HOME", "/tmp/vesper-cache")) / "swiftpm"
result = ["--swift-sdk", "arm64-apple-ios", "--cache-path", str(cache)] + result
os.environ.pop("SWIFTPM_CUSTOM_BIN_DIR", None)
code = subprocess.call([shutil.which("swift"), sys.argv[1]] + result)
if code == 0 and sys.argv[1] == "build" and "--show-bin-path" not in args:
    mode = "release" if "release" in args else "debug"
    root = Path(".build")
    native = root / "arm64-apple-ios" / mode
    destination = root / "out" / "Products" / (mode.capitalize() + "-iphoneos")
    destination.mkdir(parents=True, exist_ok=True)
    for binary in native.glob("*-App"):
        if binary.is_file():
            shutil.copy2(binary, destination / binary.name)
    # Preserve SwiftPM resources used by AetherEngine.
    for bundle in native.glob("*.bundle"):
        shutil.copytree(bundle, destination / bundle.name, dirs_exist_ok=True)
    # xtool discovers binary targets and embeds their dynamic frameworks from this directory.
    for framework in native.glob("*.framework"):
        copied = destination / framework.name
        executable = framework / framework.stem
        data = executable.read_bytes()
        if data[:4] == b"\xca\xfe\xba\xbe":
            count = struct.unpack_from(">I", data, 4)[0]
            slices = [struct.unpack_from(">IIIII", data, 8 + index * 20) for index in range(count)]
            arm64 = next((item for item in slices if item[0] == 0x0100000C), None)
            if arm64 is None:
                sys.exit(f"Missing arm64 slice in {framework.name}")
            _, _, offset, size, _ = arm64
            if offset + size > len(data):
                sys.exit(f"Invalid architecture slice in {framework.name}")
            data = data[offset:offset + size]
        if copied.exists():
            shutil.rmtree(copied)
        # Static XCFrameworks are already linked into the executable. Embedding
        # them as dynamic frameworks produces an invalid app bundle.
        if data.startswith(b"!<arch>\n"):
            continue
        shutil.copytree(framework, copied, dirs_exist_ok=True)
        (copied / framework.stem).write_bytes(data)
sys.exit(code)
