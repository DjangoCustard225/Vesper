#!/usr/bin/env python3
"""Check the packaged app against the source, then write its portable checksum."""
import hashlib
import pathlib
import plistlib
import re
import struct
import sys
import zipfile


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
        for key in ("CFBundleDisplayName", "CFBundleShortVersionString", "CFBundleVersion"):
            if actual.get(key) != expected[key]:
                raise ValueError(f"Packaged {key} does not match Vesper/Info.plist")
        if actual.get("CFBundleIdentifier") != bundle_id or actual.get("MinimumOSVersion") != minimum_os:
            raise ValueError("Packaged bundle identifier or minimum iOS version does not match the project")
        executable = archive.read(prefix + actual["CFBundleExecutable"])
        if len(executable) < 32 or struct.unpack_from("<II", executable) != (0xFEEDFACF, 0x0100000C):
            raise ValueError("Expected a 64-bit ARM Mach-O executable")
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
    checksum = ipa.with_name("SHA256SUMS.txt")
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
