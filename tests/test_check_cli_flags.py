#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local check` flag and refusal parity."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "check is a feature of the Zig build")
class CheckCliFlags(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-check-flags-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def run_check(self, args, **env_overrides):
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
            "EB_LOCAL_PREFIX": str(self.root / "prefix"),
        }
        env.update(env_overrides)
        return subprocess.run(
            [binary.BIN, "check", *args],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_requires_targets_and_rejects_mixed_modes(self):
        empty = self.run_check([])
        self.assertEqual(empty.returncode, 2, empty.stdout + empty.stderr)
        self.assertEqual(empty.stdout, "")
        self.assertIn("check needs one or more programs or libraries", empty.stderr)

        for args in (
            ["--dev", "--prefix", str(self.root)],
            ["--module", "Demo/1.0", "--prefix", str(self.root)],
            ["--prefix", str(self.root), str(self.root / "prog")],
        ):
            with self.subTest(args=args):
                got = self.run_check(args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("takes files, or one of --module, --dev and --prefix", got.stderr)

    def test_non_elf_and_absent_files_exit_two(self):
        script = self.root / "script.sh"
        script.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        got = self.run_check([str(script)])
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("not a 64-bit little-endian ELF file", got.stderr)

        got_json = self.run_check(["--json", str(script)])
        self.assertEqual(got_json.returncode, 2, got_json.stdout + got_json.stderr)
        doc = json.loads(got_json.stdout)
        self.assertTrue(doc["unreadable"])
        self.assertEqual(doc["elf_count"], 0)

        absent = self.run_check([str(self.root / "no-such-file")])
        self.assertEqual(absent.returncode, 2, absent.stdout + absent.stderr)
        self.assertIn("cannot open", absent.stderr)

    def test_empty_prefix_dir_exits_zero_in_text_and_json_modes(self):
        empty_dir = self.root / "empty-tree"
        empty_dir.mkdir()
        text = self.run_check(["--prefix", str(empty_dir)])
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertIn("no ELF files", text.stdout)
        self.assertIn("no problems", text.stdout)

        doc_run = self.run_check(["--prefix", str(empty_dir), "--json"])
        self.assertEqual(doc_run.returncode, 0, doc_run.stderr)
        doc = json.loads(doc_run.stdout)
        self.assertEqual(doc["elf_count"], 0)
        self.assertFalse(doc["unreadable"])
        self.assertEqual(doc["problem_count"], 0)

    def test_dev_env_requirements_and_module_version_refusals(self):
        no_dev = self.run_check(
            ["--dev"],
            EB_LOCAL_DEV_PREFIX="",
            EESSI_VERSION="",
            EESSI_SOFTWARE_SUBDIR="",
        )
        self.assertEqual(no_dev.returncode, 2, no_dev.stdout + no_dev.stderr)
        self.assertIn("check --dev needs EB_LOCAL_DEV_PREFIX", no_dev.stderr)

        prefix = self.root / "prefix"
        real_ver = self.root / "real-versions"
        real_ver.mkdir()
        prefix.mkdir()
        (prefix / "versions").symlink_to(real_ver)
        sym = self.run_check(["--module", "Demo/1.0"])
        self.assertEqual(sym.returncode, 2, sym.stdout + sym.stderr)
        self.assertIn("reached through a symbolic link", sym.stderr)

        (prefix / "versions").unlink()
        (prefix / "versions").mkdir()
        no_ver = self.run_check(["--module", "Demo"])
        self.assertEqual(no_ver.returncode, 2, no_ver.stdout + no_ver.stderr)
        self.assertIn("has no version", no_ver.stderr)


if __name__ == "__main__":
    unittest.main()
