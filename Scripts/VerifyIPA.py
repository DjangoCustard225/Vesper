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


def verify(ipa, root, go=False, *, unstripped=False, write_checksum=True, native_icon=False):
    configuration_root = root / "Go" if go else root
    expected = plistlib.loads((root / "Go/Info.plist" if go else root / "Vesper/Info.plist").read_bytes())
    bundle_id = re.search(r"^bundleID:\s*(\S+)\s*$", (configuration_root / "xtool.yml").read_text(), re.M).group(1)
    minimum_os = re.search(r'\.iOS\("([\d.]+)"\)', (configuration_root / "Package.swift").read_text()).group(1)
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
        required = {"_mpv_create", "_mpv_initialize", "_mpv_command_async", "_mpv_set_property_async",
                    "_mpv_terminate_destroy", "_video_out_gpu_next", "_ra_ctx_vulkan_moltenvk"}
        if go:
            if any(".framework/" in name or name.endswith(".a") or "AetherEngine" in name or "MPVKit" in name for name in names):
                raise ValueError("Vesper Go must not contain player frameworks, archives or resources")
            symbols = commands.get("symbols", set()) | set(commands.get("imports", {}))
            forbidden = ("MPVPlaybackController", "MPVSession", "AetherPlaybackController", "12AetherEngine",
                         "BuiltInPlayerView", "PlayerGesturePreferences", "PlaybackTimeline", "PlaybackRequest",
                         "PlaybackProgressReporter", "PlaybackProgressUpdate", "resumePosition",
                         "resumeRecord", "continueWatching", "removeRetiredPreferences", "showContinueWatching",
                         "13WatchProgressV6record", "11VideoPlayerO7builtIn", "11VideoPlayerO6aether",
                         "TraktPlaybackReporter", "TraktPlaybackSample", "TraktScrobble", "scrobbleBody")
            prefixes = ("_mpv_", "_av_", "_avcodec_", "_avformat_", "_avfilter_", "_dovi_",
                        "_OBJC_CLASS_$_AVPlayer", "_OBJC_CLASS_$_AVQueuePlayer", "_OBJC_CLASS_$_AVSampleBuffer")
            if any(any(part in symbol for part in forbidden) or symbol.startswith(prefixes) for symbol in symbols):
                raise ValueError("Vesper Go unexpectedly contains built-in playback code")
            if any(value in executable for value in (b"scrobble/", b"traktScrobbling", b"Scrobble playback")):
                raise ValueError("Vesper Go unexpectedly contains Trakt scrobbling code")
            for dependency in commands.get("dylibs", []):
                if not dependency.startswith(("/usr/lib/", "/System/Library/", "@rpath/libswift")):
                    raise ValueError(f"Unexpected Vesper Go dependency: {dependency}")
        else:
            mpv = arm64_commands(archive.read(prefix + "Frameworks/Libmpv.framework/Libmpv"))
            if not {name for name in required if name.startswith("_mpv_")} <= mpv.get("exports", set()):
                raise ValueError("The isolated mpv client API is missing")
            if unstripped and not required <= mpv.get("symbols", set()):
                raise ValueError("The isolated mpv engine or its Metal renderer is missing")
            if unstripped and not {"_avformat_open_input", "_avcodec_send_packet"} <= mpv.get("symbols", set()):
                raise ValueError("mpv is missing its private FFmpeg implementation")
            # lld retains these common AVS3 tables as exports even with an API export list.
            common_tables = {"_g_tbl_itrans", "_g_tbl_itrans_coeffs", "_uavs3d_funs_handle"}
            if any(not name.startswith("_mpv_") and name not in common_tables for name in mpv.get("exports", set())):
                raise ValueError("mpv exports internal symbols that may collide with AetherEngine")
            if any("VLCKit" in name for name in names):
                raise ValueError("A VLC framework or resource is unexpectedly packaged")
            symbols = commands.get("symbols", set())
            if unstripped and not all(any(part in symbol for symbol in symbols)
                       for part in ("12AetherEngine", "AetherPlaybackController", "MPVPlaybackController")):
                raise ValueError("One of the built-in player engines or adapters is missing")
            binaries = [(actual["CFBundleExecutable"], commands)]
            frameworks = set()
            linked_frameworks = {}
            for name in names:
                if name.startswith(prefix + "Frameworks/") and name.endswith(".framework/Info.plist"):
                    framework = plistlib.loads(archive.read(name))
                    executable = name.removesuffix("Info.plist") + framework["CFBundleExecutable"]
                    linked = arm64_commands(archive.read(executable))
                    if linked.get("platform") != 2 or linked.get("minimum_os", 0) > 27 << 16:
                        raise ValueError(f"Incompatible embedded framework: {executable}")
                    frameworks.add(pathlib.PurePosixPath(name).parent.name)
                    binaries.append((executable, linked))
                    for install_name in linked.get(0xD, []):
                        linked_frameworks[install_name] = linked
            artifacts = json.loads((root / "Dependencies/AetherEngine/artifacts.json").read_text())["artifacts"]
            expected_frameworks = {pathlib.PurePosixPath(path).name.replace(".xcframework", ".framework")
                                   for artifact in artifacts if artifact["name"] == "FFmpegBuild" for path in artifact["frameworks"]}
            expected_frameworks.add("Libmpv.framework")
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
            for symbol, framework in [("_mpv_create", "Libmpv"), ("_avformat_open_input", "AetherLibavformat"),
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
            for player in ("MPVKit", "AetherEngine"):
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
    parser.add_argument("--go", action="store_true")
    parser.add_argument("--unstripped", action="store_true", help="Also audit private engine and adapter symbols before release stripping")
    parser.add_argument("--native-icon", action="store_true", help="Require the compiled Icon Composer app icon")
    arguments = parser.parse_args()
    try:
        verify(pathlib.Path(arguments.ipa) if arguments.ipa else project / ("xtool/VesperGo.ipa" if arguments.go else "xtool/Vesper.ipa"), project, go=arguments.go, unstripped=arguments.unstripped, native_icon=arguments.native_icon)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        sys.exit(f"Verification failed: {error}")
