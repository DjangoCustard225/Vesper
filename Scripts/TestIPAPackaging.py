"""Regression checks for release binary validation and safe stripping."""
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import OptimizeIPA
from VerifyIPA import LinkeditAlignmentError, arm64_commands


def executable(symoff=64, stroff=80, strsize=16):
    data = bytearray(96)
    struct.pack_into("<8I", data, 0, 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
    struct.pack_into("<6I", data, 32, 2, 24, symoff, 1, stroff, strsize)
    return bytes(data)


class PackagingTests(unittest.TestCase):
    def test_aligned_tables_are_accepted(self):
        arm64_commands(executable())

    def test_misaligned_string_pool_is_rejected(self):
        with self.assertRaises(LinkeditAlignmentError):
            arm64_commands(executable(stroff=84, strsize=12))

    def test_misaligned_symbol_table_is_rejected(self):
        with self.assertRaises(LinkeditAlignmentError):
            arm64_commands(executable(symoff=68, stroff=88, strsize=8))

    def test_out_of_bounds_string_pool_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "extends beyond"):
            arm64_commands(executable(strsize=24))

    def test_optimizer_retains_original_when_stripper_breaks_alignment(self):
        original = executable()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / "VesperGo.ipa"
            name = "Payload/VesperGo.app/VesperGo"
            with zipfile.ZipFile(ipa, "w") as archive:
                archive.writestr(name, original)

            def strip(arguments, **kwargs):
                Path(arguments[-1]).write_bytes(executable(stroff=84, strsize=12))

            with patch.object(OptimizeIPA, "verify"), \
                    patch.object(OptimizeIPA, "strip_command", return_value=["strip"]), \
                    patch.object(OptimizeIPA.subprocess, "run", side_effect=strip):
                OptimizeIPA.optimize(ipa, root, go=True)
            with zipfile.ZipFile(ipa) as archive:
                self.assertEqual(archive.read(name), original)
                arm64_commands(archive.read(name))


if __name__ == "__main__":
    unittest.main()
