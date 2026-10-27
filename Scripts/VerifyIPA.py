#!/usr/bin/env python3
"""Check the packaged app against the source, then write its portable checksum."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import struct
import sys
import zipfile


class LinkeditAlignmentError(ValueError):
    """The loader cannot use a misaligned 64-bit LINKEDIT table."""


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
        if command in (0xC, 0xD, 0x80000018, 0x8000001C, 0x8000001F):
            start = struct.unpack_from("<I", data, offset + 8)[0]
            path = data[offset + start:offset + size].split(b"\0")[0].decode()
            commands.setdefault(command, []).append(path)
            if command in (0xC, 0x80000018, 0x8000001F):
                commands.setdefault("dylibs", []).append(path)
        if command == 0x2:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, offset + 8)
            for name, position, length in (("symbol table", symoff, nsyms * 16),
                                            ("string pool", stroff, strsize)):
                if length and position % 8:
                    raise LinkeditAlignmentError(f"Misaligned LINKEDIT {name} at 0x{position:X}")
                if position + length > len(data):
                    raise ValueError(f"LINKEDIT {name} extends beyond the binary")
            symbols, exports, imports, aliases = set(), set(), {}, {}
            for index in range(nsyms):
                start, kind, section, description, value = struct.unpack_from("<IBBHQ", data, symoff + index * 16)
                if start < strsize:
                    end = data.find(b"\0", stroff + start, stroff + strsize)
                    if end < 0:
                        raise ValueError("Invalid symbol name")
                    name = data[stroff + start:end].decode()
                    if kind & 0x0E == 0x0E:
                        symbols.add(name)
                        if kind & 1 and not kind & 0x10:
                            exports.add(name)
                    elif kind & 0x0E == 0 and kind & 1:
                        imports[name] = description >> 8
                    elif kind & 0x0E == 0x0A and value < strsize:
                        alias_end = data.find(b"\0", stroff + value, stroff + strsize)
                        aliases[name] = data[stroff + value:alias_end].decode()
            commands["symbols"] = symbols
            commands["exports"] = exports
            commands["imports"] = imports
            commands["aliases"] = aliases
        if command == 0x32:
            commands["platform"], commands["minimum_os"] = struct.unpack_from("<II", data, offset + 8)
        offset += size
    return commands


def verify_player_dependencies(commands, names=()):
    forbidden = ("MPVPlaybackController", "MPVSession", "MPVVideoSurface", "MPVSnapshot")
    symbols = commands.get("symbols", set()) | set(commands.get("imports", {})) | commands.get("exports", set())
    if any(symbol.startswith("_mpv_") or any(part in symbol for part in forbidden) for symbol in symbols):
        raise ValueError("Removed mpv playback code is present in the application")
    if any("Libmpv" in name or "MPVKit" in name or "MoltenVK" in name for name in names):
        raise ValueError("Removed mpv frameworks or resources are packaged")


def verify(ipa, root, *, unstripped=False, write_checksum=True, native_icon=False):
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
        for key in ("CFBundleDisplayName", "CFBundleShortVersionString", "CFBundleVersion", "CFBundleURLTypes", "LSApplicationQueriesSchemes"):
            if actual.get(key) != expected[key]:
                raise ValueError(f"Packaged {key} does not match Vesper/Info.plist")
        if actual.get("CFBundleIdentifier") != bundle_id or actual.get("MinimumOSVersion") != minimum_os:
            raise ValueError("Packaged bundle identifier or minimum iOS version does not match the project")
        executable = archive.read(prefix + actual["CFBundleExecutable"])
        commands = arm64_commands(executable)
        if commands.get("platform") != 2 or commands.get("minimum_os") != 27 << 16:
            raise ValueError("Expected an iOS 27 device executable")
        verify_player_dependencies(commands, names)
        if any("VLCKit" in name for name in names):
            raise ValueError("A VLC framework or resource is unexpectedly packaged")
        symbols = commands.get("symbols", set())
        if unstripped and not all(any(part in symbol for symbol in symbols)
                   for part in ("12AetherEngine", "AetherPlaybackController")):
            raise ValueError("The AVPlayer engine or adapter is missing")
        binaries = [(actual["CFBundleExecutable"], commands)]
        frameworks = set()
        linked_frameworks = {}
        for name in names:
            if name.startswith(prefix + "Frameworks/") and name.endswith(".framework/Info.plist"):
                framework = plistlib.loads(archive.read(name))
                executable = name.removesuffix("Info.plist") + framework["CFBundleExecutable"]
                linked = arm64_commands(archive.read(executable))
                verify_player_dependencies(linked)
                if linked.get("platform") != 2 or linked.get("minimum_os", 0) > 27 << 16:
                    raise ValueError(f"Incompatible embedded framework: {executable}")
                frameworks.add(pathlib.PurePosixPath(name).parent.name)
                binaries.append((executable, linked))
                for install_name in linked.get(0xD, []):
                    linked_frameworks[install_name] = linked
        artifacts = json.loads((root / "Dependencies/AetherEngine/artifacts.json").read_text())["artifacts"]
        expected_frameworks = {pathlib.PurePosixPath(path).name.replace(".xcframework", ".framework")
                               for artifact in artifacts if artifact["name"] == "FFmpegBuild" for path in artifact["frameworks"]}
        if frameworks != expected_frameworks:
            raise ValueError(f"Embedded frameworks differ from the pinned engine: {frameworks}")
        def reaches(library, expected, symbol, visited):
            if library == expected:
                return True
            if (library, symbol) in visited:
                return False
            visited.add((library, symbol))
            linked = linked_frameworks.get(library, {})
            # FFmpeg also re-exports individual functions through N_INDR aliases.
            alias = linked.get("aliases", {}).get(symbol)
            ordinal = linked.get("imports", {}).get(alias, 0)
            dependencies = linked.get("dylibs", [])
            if alias and 0 < ordinal <= len(dependencies) and reaches(dependencies[ordinal - 1], expected, alias, visited):
                return True
            return any(reaches(path, expected, symbol, visited) for path in linked.get(0x8000001F, []))
        libraries = commands.get("dylibs", [])
        for symbol, framework in [("_avformat_open_input", "AetherLibavformat"),
                                  ("_avcodec_send_packet", "AetherLibavcodec")]:
            expected_library = f"@rpath/{framework}.framework/{framework}"
            ordinal = commands.get("imports", {}).get(symbol, 0)
            if not 0 < ordinal <= len(libraries) or not reaches(libraries[ordinal - 1], expected_library, symbol, set()):
                raise ValueError(f"{symbol} is bound to the wrong playback engine")
        for binary, linked in binaries:
            for path in linked.get(0xC, []) + linked.get(0x80000018, []) + linked.get(0x8000001F, []):
                if path.startswith(("/usr/lib/", "/System/Library/", "@rpath/libswift")):
                    continue
                if path.startswith("@rpath/") and prefix + "Frameworks/" + path[7:] in names:
                    continue
                raise ValueError(f"Unresolved dependency in {binary}: {path}")
        if any(name.endswith(".a") for name in names):
            raise ValueError("Static dependencies should be linked, not embedded")
        if prefix + "AetherEngine_AetherEngine.bundle/silent-atmos.mp4" not in names:
            raise ValueError("AetherEngine resource bundle is missing")
        for player in ("AetherEngine",):
            license_name = player + "-LICENSE.txt"
            if archive.read(prefix + license_name) != (root / "Vesper/Resources" / license_name).read_bytes():
                raise ValueError(f"Packaged {player} license is missing or differs from the source")
        icons = actual.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconFiles", [])
        if not icons or not any(name.startswith(prefix + icon) and name.endswith(".png") for icon in icons for name in names):
            if prefix + "Assets.car" not in names:
                raise ValueError("Packaged app icon is missing")
        if native_icon:
            primary = actual.get("CFBundleIcons", {}).get("CFBundlePrimaryIcon", {})
            if primary.get("CFBundleIconName") != "VesperIcon" or prefix + "Assets.car" not in names:
                raise ValueError("The native clear/tinted app icon was not compiled or selected")
        privacy = plistlib.loads(archive.read(prefix + "PrivacyInfo.xcprivacy"))
        if privacy.get("NSPrivacyTracking") is not False:
            raise ValueError("Packaged privacy manifest must declare tracking disabled")
    print(f"Verified {actual['CFBundleDisplayName']} {actual['CFBundleShortVersionString']} ({actual['CFBundleVersion']}), {bundle_id}, iOS {minimum_os}+")
    if not write_checksum:
        return
    digest = hashlib.sha256()
    with ipa.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    checksum = ipa.with_suffix(".sha256")
    temporary = checksum.with_suffix(".tmp")
    temporary.write_text(f"{digest.hexdigest()}  {ipa.name}\n")
    temporary.replace(checksum)
    print(f"SHA256: {digest.hexdigest()}")


if __name__ == "__main__":
    project = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", nargs="?")
    parser.add_argument("--unstripped", action="store_true", help="Also audit private engine and adapter symbols before release stripping")
    parser.add_argument("--native-icon", action="store_true", help="Require the compiled Icon Composer app icon")
    arguments = parser.parse_args()
    try:
        verify(pathlib.Path(arguments.ipa) if arguments.ipa else project / "xtool/Vesper.ipa", project, unstripped=arguments.unstripped, native_icon=arguments.native_icon)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        sys.exit(f"Verification failed: {error}")
