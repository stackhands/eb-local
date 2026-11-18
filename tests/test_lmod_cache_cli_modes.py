#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local lmod-cache` modes and path validation."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


@unittest.skipUnless(binary.BIN, "lmod-cache is a feature of the Zig build")
class LmodCacheCliModes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-lmod-cache-modes-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()

    def run_cache(self, args):
        return subprocess.run(
            [binary.BIN, "lmod-cache", *args],
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.root)},
            cwd=self.root,
            capture_output=True,
            text=True,
        )

    def test_prefix_mode_rejects_verify_and_spider_flags(self):
        for extra in (["--verify"], ["--spider", "/bin/true"]):
            with self.subTest(extra=extra):
                got = self.run_cache(["--prefix", str(self.root), *extra])
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn("applies only with --modulepath", got.stderr)

    def test_relative_paths_and_empty_modulepath_are_rejected_with_exit_two(self):
        cases = [
            (["--prefix", "relative/dir"], "not an absolute path"),
            (["--modulepath", "relative/mods", "--cache-dir", str(self.root), "--timestamp", str(self.root / "ts")], "not an absolute path"),
            (["--modulepath", str(self.root), "--cache-dir", "relative/cache", "--timestamp", str(self.root / "ts")], "not an absolute path"),
            (["--modulepath", str(self.root), "--cache-dir", str(self.root), "--timestamp", "relative/ts"], "not an absolute path"),
            (["--modulepath", ":::", "--cache-dir", str(self.root), "--timestamp", str(self.root / "ts")], "names no directory"),
        ]
        for args, needle in cases:
            with self.subTest(args=args):
                got = self.run_cache(args)
                self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
                self.assertEqual(got.stdout, "")
                self.assertIn(needle, got.stderr)

    def test_prefix_dry_run_on_empty_prefix_exits_one(self):
        empty = self.root / "empty-prefix"
        empty.mkdir()
        got = self.run_cache(["--prefix", str(empty), "--dry-run"])
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertEqual(got.stdout, "")
        self.assertIn("found no CPU target", got.stderr)

    def test_prefix_update_cmd_failure_propagates_exit_status(self):
        arch = self.root / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        (arch / "modules" / "all").mkdir(parents=True)
        updater = self.root / "fail-updater.sh"
        updater.write_text("#!/bin/sh\necho updater failed >&2\nexit 9\n", encoding="utf-8")
        updater.chmod(0o755)
        got = self.run_cache(["--prefix", str(self.root), "--update-cmd", str(updater)])
        self.assertEqual(got.returncode, 9, got.stdout + got.stderr)
        self.assertIn("updater failed", got.stderr)
        self.assertFalse((arch / ".lmod" / "cache" / "spiderT.lua").exists())


if __name__ == "__main__":
    unittest.main()
