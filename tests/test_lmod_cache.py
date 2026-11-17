#!/usr/bin/env python3
"""`eb-local lmod-cache` writes a spider cache Lmod will trust."""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import binary

SPIDER = """#!/bin/sh
printf 'spider-cache\\n'
"""

FAILING = """#!/bin/sh
echo spider-failed >&2
exit 9
"""

UPDATE = """#!/bin/sh
echo "$0 $@" >>"$EB_LOCAL_UPDATE_LOG"
exit 0
"""


def run(args):
    return subprocess.run(
        [binary.BIN, "lmod-cache", *args],
        capture_output=True,
        text=True,
    )


@unittest.skipUnless(binary.BIN, "EB_LOCAL_BIN names the Zig build")
class LmodCache(unittest.TestCase):
    def test_a_successful_spider_leaves_the_timestamp_older_than_the_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            spider = root / "spider"
            spider.write_text(SPIDER)
            spider.chmod(spider.stat().st_mode | stat.S_IEXEC)
            modules = root / "modules"
            modules.mkdir()
            cache = root / "cache"
            stamp = root / "system.txt"
            got = run(
                [
                    "--modulepath",
                    str(modules),
                    "--cache-dir",
                    str(cache),
                    "--timestamp",
                    str(stamp),
                    "--spider",
                    str(spider),
                ]
            )
            self.assertEqual(got.returncode, 0, got.stderr)
            body = (cache / "spiderT.lua").read_text()
            self.assertEqual(body, "spider-cache\n")
            self.assertLess(stamp.stat().st_mtime, (cache / "spiderT.lua").stat().st_mtime)
            self.assertIn("spiderT.lua", got.stdout)
            self.assertIn("older than it", got.stdout)
            self.assertFalse((cache / "spiderT.lua.new").exists())

    def test_a_failed_spider_leaves_the_previous_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            spider = root / "spider"
            spider.write_text(FAILING)
            spider.chmod(spider.stat().st_mode | stat.S_IEXEC)
            cache = root / "cache"
            cache.mkdir()
            previous = cache / "spiderT.lua"
            previous.write_text("previous\n")
            stamp = root / "system.txt"
            stamp.write_text("old\n")
            before_cache = previous.stat().st_mtime_ns
            before_stamp = stamp.stat().st_mtime_ns
            got = run(
                [
                    "--modulepath",
                    str(root / "modules"),
                    "--cache-dir",
                    str(cache),
                    "--timestamp",
                    str(stamp),
                    "--spider",
                    str(spider),
                ]
            )
            self.assertEqual(got.returncode, 9, got.stderr)
            self.assertEqual(previous.read_text(), "previous\n")
            self.assertEqual(previous.stat().st_mtime_ns, before_cache)
            self.assertEqual(stamp.stat().st_mtime_ns, before_stamp)
            self.assertIn("the cache was not changed", got.stderr)
            self.assertIn("spider-failed", got.stderr)

    def test_a_relative_cache_directory_is_refused(self):
        got = run(["--modulepath", "/modules", "--cache-dir", "cache", "--timestamp", "/tmp/stamp"])
        self.assertEqual(got.returncode, 2, got.stderr)
        self.assertIn("not an absolute path", got.stderr)

    def test_prefix_dry_run_lists_cpu_and_accelerator_module_trees(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / "versions/2026.06/software/linux/x86_64/amd/zen4"
            (base / "modules/all").mkdir(parents=True)
            (base / "accel/nvidia/cc90/modules/all").mkdir(parents=True)
            got = run(["--prefix", str(root), "--dry-run"])
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertIn(str(base), got.stdout)
            self.assertIn("modules/all", got.stdout)
            self.assertIn("accel/nvidia/cc90/modules/all", got.stdout)

    def test_prefix_invokes_lmods_cache_updater_for_each_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            log = root / "calls.log"
            updater = root / "update_lmod_system_cache_files"
            updater.write_text(UPDATE)
            updater.chmod(updater.stat().st_mode | stat.S_IEXEC)
            cpu = root / "versions/2026.06/software/linux/x86_64/amd/zen4"
            (cpu / "modules/all").mkdir(parents=True)
            (cpu / "accel/nvidia/cc90/modules/all").mkdir(parents=True)
            env = {**os.environ, "EB_LOCAL_UPDATE_LOG": str(log)}
            got = subprocess.run(
                [binary.BIN, "lmod-cache", "--prefix", str(root), "--update-cmd", str(updater)],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(got.returncode, 0, got.stderr)
            lines = log.read_text().strip().splitlines()
            self.assertEqual(len(lines), 1)
            self.assertIn("modules/all", lines[0])
            self.assertIn("accel/nvidia/cc90/modules/all", lines[0])
            self.assertIn(f"-d {cpu}/.lmod/cache", lines[0])


if __name__ == "__main__":
    unittest.main()
