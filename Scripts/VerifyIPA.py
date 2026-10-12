#!/usr/bin/env python3
"""Check the packaged app against the source, then write its portable checksum."""
import hashlib
import pathlib
import plistlib
import re
import struct
import sys
import zipfile


def arm64_commands(data):
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack_from(">I", data, 4)[0]
        slices = [struct.unpack_from(">IIIII", data, 8 + index * 20) for index in range(count)]
        arm64 = next((item for item in slices if item[0] == 0x0100000C), None)
        if arm64 is None:
            raise ValueError("Packaged binary has no arm64 slice")
        data = data[arm64[2]:arm64[2] + arm64[3]]
    if len(data) < 32 or struct.unpack_from("<II", data) != (0xFEEDFACF, 0x0100000C):
        raise ValueError("Expected a 64-bit ARM Mach-O executable")
    offset = 32
    commands = {}
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("Invalid Mach-O load command")
        if command in (0xC, 0xD, 0x80000018, 0x8000001C):
            start = struct.unpack_from("<I", data, offset + 8)[0]
            path = data[offset + start:offset + size].split(b"\0")[0].decode()
            commands.setdefault(command, []).append(path)
        if command == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, offset + 8)
            symbols = set()
            for index in range(nsyms):
                start, kind, section, description, value = struct.unpack_from("<IBBHQ", data, symoff + index * 16)
                if start < strsize and kind & 0x0E == 0x0E:
                    end = data.find(b"\0", stroff + start, stroff + strsize)
                    if end < 0:
                        raise ValueError("Invalid symbol name")
                    name = data[stroff + start:end].decode()
                    symbols.add(name)
            commands["symbols"] = symbols
        if command == 0x32:
            commands["platform"], commands["minimum_os"] = struct.unpack_from("<II", data, offset + 8)
        offset += size
    return commands


def verify(ipa, root):
    expected = plistlib.loads((root / "Vesper/Info.plist").read_bytes())
    bundle_id = re.search(r"^bundleID:\s*(\S+)\s*$", (root / "xtool.yml").read_text(), re.M).group(1)
    minimum_os = re.search(r'\.iOS\("([\d.]+)"\)', (root / "Package.swift").read_text()).group(1)
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError("IPA archive integrity check failed")
        names = archive.namelist()
        infos = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(infos) != 1:
            raise ValueError("Expected one packaged application")
        prefix = infos[0].removesuffix("Info.plist")
        actual = plistlib.loads(archive.read(infos[0]))
        for key in ("CFBundleDisplayName", "CFBundleShortVersionString", "CFBundleVersion", "CFBundleURLTypes"):
            if actual.get(key) != expected[key]:
                raise ValueError(f"Packaged {key} does not match Vesper/Info.plist")
        if actual.get("CFBundleIdentifier") != bundle_id or actual.get("MinimumOSVersion") != minimum_os:
            raise ValueError("Packaged bundle identifier or minimum iOS version does not match the project")
        executable = archive.read(prefix + actual["CFBundleExecutable"])
        commands = arm64_commands(executable)
        if commands.get("platform") != 2 or commands.get("minimum_os") != 27 << 16:
            raise ValueError("Expected an iOS 27 device executable")
        required = {"_mpv_create", "_mpv_initialize", "_mpv_command_async", "_mpv_set_property_async",
                    "_mpv_terminate_destroy", "_video_out_gpu_next", "_ra_ctx_vulkan_moltenvk"}
        if not required <= commands.get("symbols", set()):
            raise ValueError("The static mpv engine or its Metal renderer is missing")
        if any("VLCKit" in name for name in names):
            raise ValueError("A VLC framework or resource is unexpectedly packaged")
        for path in commands.get(0xC, []) + commands.get(0x80000018, []):
            if path.startswith(("/usr/lib/", "/System/Library/", "@rpath/libswift")):
                continue
            if path.startswith("@rpath/") and prefix + "Frameworks/" + path[7:] in names:
                continue
            raise ValueError(f"Unresolved library dependency: {path}")
        if any(name.endswith(".a") or ".framework/" in name for name in names):
            raise ValueError("Static dependencies should be linked, not embedded")
        if archive.read(prefix + "MPVKit-LICENSE.txt") != (root / "Vesper/Resources/MPVKit-LICENSE.txt").read_bytes():
            raise ValueError("Packaged MPVKit license is missing or differs from the source")
        icons = actual.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles", [])
        if not icons or not any(name.startswith(prefix + icon) and name.endswith(".png") for icon in icons for name in names):
            if prefix + "Assets.car" not in names:
                raise ValueError("Packaged app icon is missing")
        privacy = plistlib.loads(archive.read(prefix + "PrivacyInfo.xcprivacy"))
        if privacy.get("NSPrivacyTracking") is not False:
            raise ValueError("Packaged privacy manifest must declare tracking disabled")
    digest = hashlib.sha256()
    with ipa.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    checksum = ipa.with_suffix(".sha256")
    temporary = checksum.with_suffix(".tmp")
    temporary.write_text(f"{digest.hexdigest()}  {ipa.name}\n")
    temporary.replace(checksum)
    print(f"Verified Vesper {actual['CFBundleShortVersionString']} ({actual['CFBundleVersion']}), {bundle_id}, iOS {minimum_os}+")
    print(f"SHA256: {digest.hexdigest()}")


if __name__ == "__main__":
    project = pathlib.Path(__file__).resolve().parent.parent
    try:
        verify(pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else project / "xtool/Vesper.ipa", project)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        sys.exit(f"Verification failed: {error}")
