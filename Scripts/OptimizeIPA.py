"""Strip staged release binaries and compress an unsigned IPA without changing runtime content."""
import argparse
from copy import copy
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

from VerifyIPA import LinkeditAlignmentError, arm64_commands, verify


def strip_command():
    override = os.environ.get("VESPER_OBJCOPY")
    swift = shutil.which("swift")
    candidates = [override] if override else [
        shutil.which("llvm-objcopy"),
        str(Path(swift).resolve().parent / "llvm-objcopy") if swift else None,
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return [candidate, "--strip-debug", "--discard-all"]
    if not override and sys.platform == "darwin":
        tool = subprocess.check_output(["xcrun", "--find", "strip"], text=True).strip()
        return [tool, "-S", "-x"]
    raise ValueError("A Mach-O stripping tool is required; set VESPER_OBJCOPY to llvm-objcopy")


def runtime_identity(data):
    """Compare loaded sections and dyld interfaces, excluding removable symbol/debug information."""
    parsed = arm64_commands(data)
    identity = {key: value for key, value in parsed.items() if key != "symbols"}
    sections, bindings, metadata = {}, {}, []
    offset = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        command, size = struct.unpack_from("<II", data, offset)
        if command == 0x19:  # LC_SEGMENT_64
            segment = data[offset + 8:offset + 24].rstrip(b"\0")
            for index in range(struct.unpack_from("<I", data, offset + 64)[0]):
                start = offset + 72 + index * 80
                name = data[start:start + 16].rstrip(b"\0")
                address, length, position = struct.unpack_from("<QQI", data, start + 32)
                flags = struct.unpack_from("<I", data, start + 64)[0]
                if segment == b"__DWARF":
                    continue
                # Zero-fill sections occupy virtual memory but have no bytes in the file.
                contents = b"" if flags & 0xFF in (1, 0xC, 0x12) else data[position:position + length]
                sections[(segment, name)] = (address, length, flags, hashlib.sha256(contents).digest())
        elif command in (0x22, 0x80000022):  # LC_DYLD_INFO[_ONLY]
            for index in range(5):
                position, length = struct.unpack_from("<II", data, offset + 8 + index * 8)
                bindings[(command, index)] = data[position:position + length]
        elif command in (0x80000033, 0x80000034):  # Exports trie / chained fixups
            position, length = struct.unpack_from("<II", data, offset + 8)
            bindings[(command, 0)] = data[position:position + length]
        elif command == 0x1D:  # LC_CODE_SIGNATURE: only unsigned/ad-hoc input may be transformed.
            position, length = struct.unpack_from("<II", data, offset + 8)
            signature = data[position:position + length]
            magic, total, count = struct.unpack_from(">III", signature)
            if magic != 0xFADE0CC0 or total > len(signature):
                raise ValueError("Unrecognized code signature; refusing to modify binary")
            ad_hoc = False
            for index in range(count):
                kind, location = struct.unpack_from(">II", signature, 12 + index * 8)
                if kind == 0x10000 and struct.unpack_from(">I", signature, location + 4)[0] > 8:
                    raise ValueError("Identity-signed binary must be optimized before signing")
                if kind == 0 or 0x1000 <= kind < 0x1005:
                    flags = struct.unpack_from(">I", signature, location + 12)[0]
                    if not flags & 2:
                        raise ValueError("Identity-signed binary must be optimized before signing")
                    ad_hoc = True
            if not ad_hoc:
                raise ValueError("Code signature has no ad-hoc code directory")
        elif command in (0x1B, 0x8000001C, 0x32):  # UUID, rpath, build version
            metadata.append(data[offset:offset + size])
        offset += size
    identity.update(sections=sections, bindings=bindings, metadata=metadata,
                    header=struct.unpack_from("<IIII", data, 0) + (struct.unpack_from("<I", data, 24)[0],))
    return identity


def optimize(ipa, root, go=False):
    # Private-symbol checks must happen before their removal, particularly Go's exclusion audit.
    verify(ipa, root, go=go, unstripped=True, write_checksum=False)
    tool = strip_command()
    original_size = ipa.stat().st_size
    with tempfile.TemporaryDirectory(prefix="vesper-ipa-", dir=ipa.parent) as directory:
        staging = Path(directory)
        output = staging / ipa.name
        with zipfile.ZipFile(ipa) as source:
            entries = source.infolist()
            names = [item.filename for item in entries]
            if len(names) != len(set(names)):
                raise ValueError("Duplicate IPA entries")
            if any((len(Path(name).parts) >= 3 and Path(name).parts[2] == "_CodeSignature")
                   or name.endswith("embedded.mobileprovision") for name in names):
                raise ValueError("Optimize the unsigned IPA before signing")
            original_unpacked = sum(item.file_size for item in entries)
            with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as destination:
                destination.comment = source.comment
                for entry in entries:
                    data = source.read(entry)
                    if data[:4] == b"\xcf\xfa\xed\xfe":
                        before = runtime_identity(data)
                        # LLVM rewrites the string table without fixing Mach-O N_INDR targets.
                        # Aether's prebuilt re-export libraries must retain their original bytes.
                        if not before.get("aliases"):
                            binary = staging / "input"
                            binary.write_bytes(data)
                            subprocess.run(tool + [str(binary)], check=True, capture_output=True, text=True)
                            result = binary.read_bytes()
                            try:
                                arm64_commands(result)
                            except LinkeditAlignmentError:
                                # Some LLVM versions omit 64-bit string-pool padding. Keep the
                                # valid input instead of shipping a binary dyld cannot load.
                                print(f"Kept {entry.filename}: stripping produced invalid LINKEDIT alignment", flush=True)
                                result = data
                            if runtime_identity(result) != before:
                                raise ValueError(f"Runtime content changed while stripping {entry.filename}")
                            if len(result) < len(data):
                                print(f"Stripped {entry.filename}: {len(data) / 2**20:.2f} → {len(result) / 2**20:.2f} MiB", flush=True)
                                data = result
                    item = copy(entry)
                    item.compress_type = zipfile.ZIP_DEFLATED
                    destination.writestr(item, data, compresslevel=9)
        verify(output, root, go=go, write_checksum=False)
        with zipfile.ZipFile(output) as final:
            unpacked = sum(item.file_size for item in final.infolist())
        compressed = output.stat().st_size
        if compressed >= original_size:
            raise ValueError("Optimized IPA is not smaller than the original")
        output.replace(ipa)
    verify(ipa, root, go=go)
    print(f"IPA download: {original_size / 2**20:.2f} → {compressed / 2**20:.2f} MiB")
    print(f"Unpacked bundle: {original_unpacked / 2**20:.2f} → {unpacked / 2**20:.2f} MiB")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--go", action="store_true")
    arguments = parser.parse_args()
    try:
        optimize(arguments.ipa, Path(__file__).resolve().parent.parent, go=arguments.go)
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        sys.exit(f"IPA optimization failed: {detail}")
