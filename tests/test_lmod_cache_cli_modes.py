#!/usr/bin/env python3
"""Black-box CLI behavior tests for `eb-local lmod-cache` modes and path validation."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import binary
import hostile_fs


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

    def test_hostile_cache_and_timestamp_destinations_fail_cleanly(self):
        mods = self.root / "mods"
        mods.mkdir()
        spider = self.root / "spider.sh"
        spider.write_text("#!/bin/sh\necho 'spiderT = {}'\n", encoding="utf-8")
        spider.chmod(0o755)

        ro_dir = self.root / "ro-cache"
        ro_dir.mkdir()
        with hostile_fs.readonly_dir(ro_dir):
            ro_ts = self.root / "ro-ts"
            ro_got = self.run_cache(["--modulepath", str(mods), "--cache-dir", str(ro_dir), "--timestamp", str(ro_ts), "--spider", str(spider)])
            self.assertEqual(ro_got.returncode, 1, ro_got.stdout + ro_got.stderr)
            self.assertFalse(ro_ts.exists())

        dir_cache = self.root / "dir-cache"
        dir_cache.mkdir()
        (dir_cache / "spiderT.lua").mkdir()
        dir_ts = self.root / "dir-ts"
        dir_got = self.run_cache(["--modulepath", str(mods), "--cache-dir", str(dir_cache), "--timestamp", str(dir_ts), "--spider", str(spider)])
        self.assertEqual(dir_got.returncode, 1, dir_got.stdout + dir_got.stderr)
        self.assertFalse(dir_ts.exists())

        sym_cache = self.root / "sym-cache"
        sym_cache.mkdir()
        link, outside = hostile_fs.dangling_symlink(sym_cache / "spiderT.lua", self.root / "outside-spider")
        sym_ts = self.root / "sym-ts"
        sym_got = self.run_cache(["--modulepath", str(mods), "--cache-dir", str(sym_cache), "--timestamp", str(sym_ts), "--spider", str(spider)])
        self.assertEqual(sym_got.returncode, 1, sym_got.stdout + sym_got.stderr)
        self.assertTrue(link.is_symlink())
        self.assertFalse(outside.exists())
        self.assertFalse(sym_ts.exists())

        ts_is_dir = self.root / "ts-is-dir"
        ts_is_dir.mkdir()
        clean_cache = self.root / "clean-cache"
        clean_cache.mkdir()
        ts_got = self.run_cache(["--modulepath", str(mods), "--cache-dir", str(clean_cache), "--timestamp", str(ts_is_dir), "--spider", str(spider)])
        self.assertEqual(ts_got.returncode, 1, ts_got.stdout + ts_got.stderr)
        self.assertFalse((clean_cache / "spiderT.lua").exists())

    def test_tmpfs_enospc_rolls_back_cache_and_timestamp(self):
        mnt = hostile_fs.enter_full_tmpfs(self)
        if mnt is None:
            return
        mods = self.root / "mods-enospc"
        mods.mkdir()
        spider = self.root / "spider-enospc.sh"
        spider.write_text("#!/bin/sh\necho 'spiderT = {}'\n", encoding="utf-8")
        spider.chmod(0o755)
        got = self.run_cache([
            "--modulepath", str(mods),
            "--cache-dir", str(mnt / "lc"),
            "--timestamp", str(mnt / "ts"),
            "--spider", str(spider),
        ])
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn("NoSpace", got.stderr)


if __name__ == "__main__":
    unittest.main()
