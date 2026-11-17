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


if __name__ == "__main__":
    unittest.main()
