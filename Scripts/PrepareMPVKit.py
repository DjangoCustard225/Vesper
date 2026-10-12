"""Prepare checksum-pinned MPVKit iOS archives for Vesper’s built-in player."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
DESTINATION = ROOT / "Dependencies/MPVKit"
MANIFEST = json.loads((DESTINATION / "artifacts.json").read_text())


def prepare():
    cache = Path(os.environ.get("XDG_CACHE_HOME", "/tmp/vesper-cache")) / "mpvkit"
    cache.mkdir(parents=True, exist_ok=True)
    for artifact in MANIFEST["artifacts"]:
        name, checksum = artifact["name"], artifact["sha256"]
        target = DESTINATION / (name + ".xcframework")
        marker = DESTINATION / (name + ".sha256")
        if target.is_dir() and marker.exists() and marker.read_text().strip() == checksum:
            continue
        archive = cache / (name + ".xcframework.zip")
        if not archive.exists():
            temporary = archive.with_suffix(".download")
            subprocess.run(["curl", "-L", "--fail", "--retry", "2", "-o", str(temporary), artifact["url"]], check=True)
            temporary.replace(archive)
        with archive.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != checksum:
                raise SystemExit(f"Checksum mismatch for {name}; remove its cached archive and retry.")
        with tempfile.TemporaryDirectory(prefix="vesper-mpv-") as staging:
            with zipfile.ZipFile(archive) as source:
                folder = name + ".xcframework"
                info = plistlib.loads(source.read(folder + "/Info.plist"))
                libraries = [item for item in info["AvailableLibraries"]
                             if item["SupportedPlatform"] == "ios" and item.get("SupportedPlatformVariant") != "maccatalyst"]
                if not any("arm64" in item["SupportedArchitectures"] and not item.get("SupportedPlatformVariant") for item in libraries):
                    raise SystemExit(f"No iOS arm64 slice in {name}")
                prefixes = tuple(folder + "/" + item["LibraryIdentifier"] + "/" for item in libraries)
                for entry in source.infolist():
                    if not entry.filename.startswith(prefixes):
                        continue
                    path = PurePosixPath(entry.filename)
                    if path.is_absolute() or ".." in path.parts:
                        raise SystemExit(f"Unsafe archive entry in {name}")
                    source.extract(entry, staging)
                    if not entry.is_dir():
                        mode = (entry.external_attr >> 16) & 0o777
                        if mode:
                            (Path(staging) / entry.filename).chmod(mode)
                for item in libraries:
                    item.pop("DebugSymbolsPath", None)
                info["AvailableLibraries"] = libraries
                (Path(staging) / folder / "Info.plist").write_bytes(plistlib.dumps(info))
            if target.exists():
                shutil.rmtree(target)
            shutil.move(str(Path(staging) / folder), target)
        marker.write_text(checksum + "\n")
        print(f"Prepared {name}", flush=True)


if __name__ == "__main__":
    prepare()
