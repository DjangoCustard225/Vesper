"""Prepare pinned AetherEngine sources and iOS frameworks; keep other platforms out."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
from AetherRateTransitions import apply_rate_patches

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = json.loads((ROOT / "Dependencies/AetherEngine/artifacts.json").read_text())


def prepare():
    cache = Path(os.environ.get("XDG_CACHE_HOME", "/tmp/vesper-cache")) / "aether"
    cache.mkdir(parents=True, exist_ok=True)
    for artifact in MANIFEST["artifacts"]:
        name, checksum = artifact["name"], artifact["sha256"]
        destination = ROOT / "Dependencies" / name
        marker = destination / ".prepared-sha256"
        paths = artifact["sources"] + artifact["frameworks"]
        if marker.exists() and marker.read_text().strip() == checksum and all((destination / path).is_dir() for path in paths):
            continue
        archive = cache / f"{name}-{artifact['version']}.tar.gz"
        if not archive.exists():
            temporary = archive.with_suffix(".download")
            subprocess.run(["curl", "-L", "--fail", "--retry", "2", "-o", str(temporary), artifact["url"]], check=True)
            temporary.replace(archive)
        with archive.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != checksum:
                raise SystemExit(f"Checksum mismatch for {name}; remove its cached archive and retry.")
        with tempfile.TemporaryDirectory(prefix="vesper-aether-") as staging, tarfile.open(archive) as source:
            top = source.getmembers()[0].name.split("/")[0] + "/"
            prefixes = [path + "/" for path in artifact["sources"]]
            frameworks = {}
            for path in artifact["frameworks"]:
                info = plistlib.loads(source.extractfile(top + path + "/Info.plist").read())
                libraries = [item for item in info["AvailableLibraries"]
                             if item["SupportedPlatform"] == "ios" and item.get("SupportedPlatformVariant") != "maccatalyst"]
                if not any("arm64" in item["SupportedArchitectures"] and not item.get("SupportedPlatformVariant") for item in libraries):
                    raise SystemExit(f"No iOS arm64 slice in {path}")
                prefixes.extend(path + "/" + item["LibraryIdentifier"] + "/" for item in libraries)
                for item in libraries:
                    item.pop("DebugSymbolsPath", None)
                info["AvailableLibraries"] = libraries
                frameworks[path] = info
            for entry in source:
                if not entry.name.startswith(top):
                    continue
                relative = entry.name.removeprefix(top)
                if not (relative.startswith(tuple(prefixes)) or relative.startswith(("LICENSE", "NOTICE"))):
                    continue
                if ".dSYM" in relative or "/dSYMs/" in relative:
                    continue
                path = PurePosixPath(relative)
                if path.is_absolute() or ".." in path.parts or not (entry.isfile() or entry.isdir()):
                    raise SystemExit(f"Unsafe archive entry in {name}: {relative}")
                target = Path(staging) / path
                if entry.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.extractfile(entry) as contents, target.open("wb") as output:
                        shutil.copyfileobj(contents, output)
                    target.chmod(entry.mode & 0o777)
            for path, info in frameworks.items():
                (Path(staging) / path / "Info.plist").write_bytes(plistlib.dumps(info))
            # Replace only generated content; checked-in local manifests stay intact.
            for entry in Path(staging).iterdir():
                target = destination / entry.name
                if target.is_dir():
                    shutil.rmtree(target)
                elif target.exists():
                    target.unlink()
                shutil.move(str(entry), target)
        marker.write_text(checksum + "\n")
        print(f"Prepared {name} {artifact['version']}", flush=True)

    apply_rate_patches(ROOT / "Dependencies/AetherEngine")


if __name__ == "__main__":
    prepare()
