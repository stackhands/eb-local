#!/usr/bin/env python3
"""`eb-local lmod-cache` stdout write-error diagnostics on `/dev/full` and `1>&-`."""

from pathlib import Path
import subprocess
import tempfile
import unittest

import binary


def run_sink(argv, sink, *, env, cwd):
    if sink == "closed":
        return subprocess.run(
            ["/bin/sh", "-c", 'exec "$@" 1>&-', "sh", *argv],
            env=env,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )
    with open("/dev/full", "wb") as dev_full:
        return subprocess.run(
            argv,
            env=env,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=dev_full,
            stderr=subprocess.PIPE,
            text=True,
            timeout=5,
        )


@unittest.skipUnless(binary.ZIG, "lmod-cache stdout diagnostics belong to the Zig binary")
class LmodCacheStdoutErrorsCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-lmod-stdout-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = {
            "PATH": "/usr/bin:/bin",
            "HOME": str(self.root),
            "EB_LOCAL_CONFIG": "",
            "SLURM_JOB_ID": "",
        }

    def test_prefix_dry_run_reports_stdout_write_errors(self):
        prefix = self.root / "prefix"
        (prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "generic" / "modules" / "all").mkdir(parents=True)
        for sink, expected in (("devfull", "No space left on device"), ("closed", "Bad file descriptor")):
            with self.subTest(sink=sink):
                got = run_sink(
                    [binary.ZIG, "lmod-cache", "--prefix", str(prefix), "--dry-run"],
                    sink,
                    env=self.env,
                    cwd=self.root,
                )
                self.assertEqual(got.returncode, 1, got.stderr)
                self.assertIn("eb-local: cannot write the result:", got.stderr)
                self.assertIn(expected, got.stderr)

    def test_prefix_update_reports_stdout_write_errors_including_child_stdout(self):
        prefix = self.root / "prefix"
        (prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "generic" / "modules" / "all").mkdir(parents=True)
        update = self.root / "update-cmd"
        update.write_text("#!/bin/sh\nprintf 'updated child line\\n'\nexit 0\n", encoding="utf-8")
        update.chmod(0o755)
        for sink, expected in (("devfull", "No space left on device"), ("closed", "Bad file descriptor")):
            with self.subTest(sink=sink):
                got = run_sink(
                    [binary.ZIG, "lmod-cache", "--prefix", str(prefix), "--update-cmd", str(update)],
                    sink,
                    env=self.env,
                    cwd=self.root,
                )
                self.assertEqual(got.returncode, 1, got.stderr)
                self.assertIn("eb-local: cannot write the result:", got.stderr)
                self.assertIn(expected, got.stderr)

    def test_modulepath_spider_mode_reports_os_errno_on_stdout_write_errors(self):
        modules = self.root / "modules"
        modules.mkdir()
        spider = self.root / "spider"
        spider.write_text("#!/bin/sh\nprintf 'spiderT = {}\\n'\n", encoding="utf-8")
        spider.chmod(0o755)
        for sink, expected in (("devfull", "No space left on device"), ("closed", "Bad file descriptor")):
            with self.subTest(sink=sink):
                cache = self.root / f"cache-{sink}"
                stamp = self.root / f"system-{sink}.txt"
                got = run_sink(
                    [
                        binary.ZIG,
                        "lmod-cache",
                        "--modulepath",
                        str(modules),
                        "--cache-dir",
                        str(cache),
                        "--timestamp",
                        str(stamp),
                        "--spider",
                        str(spider),
                    ],
                    sink,
                    env=self.env,
                    cwd=self.root,
                )
                self.assertEqual(got.returncode, 1, got.stderr)
                self.assertIn("eb-local: cannot write the result:", got.stderr)
                self.assertIn(expected, got.stderr)


if __name__ == "__main__":
    unittest.main()
