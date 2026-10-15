"""Isolate mpv's static decode stack from Aether's incompatible FFmpeg ABI."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / "Dependencies/MPVKit"
DESTINATION = BASE / "MPVEngine.xcframework"
SYSTEM_FRAMEWORKS = ["AVFoundation", "CoreAudio", "AudioToolbox", "CoreVideo", "CoreFoundation",
                     "CoreMedia", "Metal", "VideoToolbox", "QuartzCore", "UIKit", "OpenGLES",
                     "Security", "Foundation", "CoreText", "CoreGraphics", "IOSurface"]


def toolchain(architecture, simulator):
    if sys.platform == "darwin":
        sdk = "iphonesimulator" if simulator else "iphoneos"
        return (subprocess.check_output(["xcrun", "--find", "ld"], text=True).strip(),
                subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip())
    triple = architecture + "-apple-ios" + ("-simulator" if simulator else "")
    for manifest in (Path.home() / ".swiftpm/swift-sdks").glob("*.artifactbundle/swift-sdk.json"):
        target = json.loads(manifest.read_text()).get("targetTriples", {}).get(triple)
        if target:
            return str(manifest.parent / "toolset/bin/ld64.lld"), str(manifest.parent / target["sdkRootPath"])
    raise SystemExit(f"Install an Apple Swift SDK for {triple} before building the player framework.")


def universal(slices):
    if len(slices) == 1:
        return slices[0]
    result = bytearray(struct.pack(">II", 0xCAFEBABE, len(slices)) + bytes(20 * len(slices)))
    for index, data in enumerate(slices):
        offset = (len(result) + 16383) & ~16383
        result.extend(bytes(offset - len(result)))
        cpu, subtype = struct.unpack_from("<II", data, 4)
        struct.pack_into(">IIIII", result, 8 + index * 20, cpu, subtype, offset, len(data), 14)
        result.extend(data)
    return result


def prepare():
    manifest = (BASE / "artifacts.json").read_bytes()
    checksum = hashlib.sha256(manifest + Path(__file__).read_bytes()).hexdigest()
    marker = BASE / "MPVEngine.sha256"
    if DESTINATION.is_dir() and marker.exists() and marker.read_text().strip() == checksum:
        return
    artifacts = json.loads(manifest)["artifacts"]
    available = []
    with tempfile.TemporaryDirectory(prefix="vesper-mpv-framework-") as staging:
        staging = Path(staging)
        for simulator in [False, True]:
            identifier = "ios-arm64_x86_64-simulator" if simulator else "ios-arm64"
            framework = staging / identifier / "Libmpv.framework"
            framework.mkdir(parents=True)
            binaries = {}
            original = None
            for artifact in artifacts:
                package = BASE / (artifact["name"] + ".xcframework")
                info = plistlib.loads((package / "Info.plist").read_bytes())
                item = next(item for item in info["AvailableLibraries"]
                            if item["SupportedPlatform"] == "ios" and
                            item.get("SupportedPlatformVariant") == ("simulator" if simulator else None))
                library = package / item["LibraryIdentifier"] / item["LibraryPath"]
                binaries[artifact["name"]] = library / artifact["name"] if library.is_dir() else library
                if artifact["name"] == "Libmpv":
                    original = library
            headers = "\n".join(path.read_text() for path in (original / "Headers").rglob("*.h"))
            exports = sorted(set(re.findall(r"MPV_EXPORT[^;]*?\b(mpv_\w+)\s*\(", headers, re.S)))
            if "mpv_create" not in exports:
                raise SystemExit("The mpv archive has no public client API")
            architectures = ["arm64", "x86_64"] if simulator else ["arm64"]
            slices = []
            for architecture in architectures:
                linker, sdk = toolchain(architecture, simulator)
                output = staging / (identifier + "-" + architecture)
                args = [linker, "-dylib", "-arch", architecture, "-platform_version",
                        "ios-simulator" if simulator else "ios", "27.0", "27.0", "-syslibroot", sdk,
                        "-install_name", "@rpath/Libmpv.framework/Libmpv", "-dead_strip", "-o", str(output),
                        "-force_load", str(binaries.pop("Libmpv", original / "Libmpv"))]
                args += [str(path) for path in binaries.values()]
                for symbol in exports:
                    args += ["-exported_symbol", "_" + symbol]
                for name in SYSTEM_FRAMEWORKS:
                    args += ["-framework", name]
                args += ["-l" + name for name in ["bz2", "iconv", "expat", "resolv", "xml2", "z", "c++", "System", "objc"]]
                result = subprocess.run(args, capture_output=True, text=True)
                if result.returncode:
                    sys.stderr.write(result.stderr)
                    raise SystemExit(result.returncode)
                slices.append(output.read_bytes())
            (framework / "Libmpv").write_bytes(universal(slices))
            (framework / "Libmpv").chmod(0o755)
            for directory in ["Headers", "Modules"]:
                shutil.copytree(original / directory, framework / directory)
            (framework / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "app.vesper.libmpv", "CFBundleExecutable": "Libmpv",
                "CFBundleName": "Libmpv", "CFBundlePackageType": "FMWK", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "27.0",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator" if simulator else "iPhoneOS"]}))
            library = dict(LibraryIdentifier=identifier, LibraryPath="Libmpv.framework",
                           SupportedArchitectures=architectures, SupportedPlatform="ios")
            if simulator:
                library["SupportedPlatformVariant"] = "simulator"
            available.append(library)
        (staging / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": available,
            "CFBundlePackageType": "XFWK", "XCFrameworkFormatVersion": "1.0"}))
        # Linked intermediates are outside the XCFramework's declared slices.
        for entry in staging.iterdir():
            if entry.is_file() and entry.name != "Info.plist":
                entry.unlink()
        if DESTINATION.exists():
            shutil.rmtree(DESTINATION)
        shutil.copytree(staging, DESTINATION)
    marker.write_text(checksum + "\n")
    print("Prepared isolated mpv framework (iOS device and simulator)", flush=True)


if __name__ == "__main__":
    prepare()
