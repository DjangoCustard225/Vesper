"""Optional xtool adapter for restricted Linux environments without SwiftBuild IPC.

xtool still performs app planning, resources, Info.plist assembly and IPA packaging.
Only SwiftPM compilation uses its native build system instead of SwiftBuild.
"""
import os
from pathlib import Path
import shutil
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
sys.exit(code)
