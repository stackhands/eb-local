#!/usr/bin/env python3
"""Concurrent writer serialization and signal cancellation in `eb-local lmod-cache`."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

import binary

GATED_SPIDER = r'''#!/usr/bin/env python3
import os, sys, time

root = os.environ["CONTROL_ROOT"]
tag = os.environ["SPIDER_TAG"]
gate = os.environ["SPIDER_GATE"]
tmp = os.path.join(root, f".{tag}.pid.{os.getpid()}.tmp")
with open(tmp, "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))
os.replace(tmp, os.path.join(root, f"{tag}.pid"))

deadline = time.monotonic() + 20.0
while not os.path.exists(gate):
    if time.monotonic() >= deadline:
        sys.exit(99)
    time.sleep(0.005)

sys.stdout.write(f"spiderT = {{ writer = '{tag}' }}\n")
sys.stdout.flush()
'''


def stop_proc(proc):
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    if proc.stdout:
        proc.stdout.close()
    if proc.stderr:
        proc.stderr.close()


def wait_until_holding_fd_or_exited(proc, target_dir, timeout=5.0):
    target = str(target_dir)
    fd_dir = Path(f"/proc/{proc.pid}/fd")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return
        try:
            for entry in fd_dir.iterdir():
                try:
                    if os.readlink(entry) == target:
                        return
                except OSError:
                    continue
        except OSError:
            if proc.poll() is not None:
                return
        time.sleep(0.005)
    raise AssertionError(f"process {proc.pid} neither exited nor opened {target}")


@unittest.skipUnless(binary.ZIG, "lmod-cache is a feature of the Zig build")
class LmodCacheWriterLock(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-lmod-lock-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.gated_spider = self.root / "gated-spider"
        self.gated_spider.write_text(GATED_SPIDER, encoding="utf-8")
        self.gated_spider.chmod(0o755)
        self.fast_spider = self.root / "fast-spider"
        self.fast_spider.write_text("#!/bin/sh\nprintf \"spiderT = { writer = 'fast' }\\n\"\n", encoding="utf-8")
        self.fast_spider.chmod(0o755)
        self.modules = self.root / "modules"
        self.modules.mkdir()

    def wait_pid_file(self, name):
        path = self.root / name
        deadline = time.monotonic() + 15.0
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, f"{name} did not appear")
            time.sleep(0.005)
        return int(path.read_text(encoding="utf-8").strip())

    def test_concurrent_writers_serialize_without_stale_overwrite_or_lock_files(self):
        gate = self.root / "release-writer1"
        cache = self.root / "serial-cache"
        stamp = self.root / "serial-stamp"
        p1 = subprocess.Popen(
            [
                binary.ZIG,
                "lmod-cache",
                "--modulepath",
                str(self.modules),
                "--cache-dir",
                str(cache),
                "--timestamp",
                str(stamp),
                "--spider",
                str(self.gated_spider),
            ],
            env={
                "PATH": "/usr/bin:/bin",
                "HOME": str(self.root),
                "CONTROL_ROOT": str(self.root),
                "SPIDER_TAG": "writer1",
                "SPIDER_GATE": str(gate),
            },
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: stop_proc(p1))
        self.wait_pid_file("writer1.pid")

        p2 = subprocess.Popen(
            [
                binary.ZIG,
                "lmod-cache",
                "--modulepath",
                str(self.modules),
                "--cache-dir",
                str(cache),
                "--timestamp",
                str(stamp),
                "--spider",
                str(self.fast_spider),
            ],
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.root), "EB_LOCAL_LOCK_TIMEOUT_MS": "10000"},
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: stop_proc(p2))
        wait_until_holding_fd_or_exited(p2, self.root)
        self.assertIsNone(p2.poll(), "second lmod-cache writer ran unlocked while first writer was active")

        gate.write_text("go\n", encoding="utf-8")
        out1, err1 = p1.communicate(timeout=10)
        out2, err2 = p2.communicate(timeout=10)
        self.assertEqual(p1.returncode, 0, out1 + err1)
        self.assertEqual(p2.returncode, 0, out2 + err2)
        self.assertEqual(sorted(p.name for p in cache.iterdir()), ["spiderT.lua"])
        self.assertEqual((cache / "spiderT.lua").read_text(encoding="utf-8"), "spiderT = { writer = 'fast' }\n")

    def test_signal_cancels_contended_lmod_cache_waiter(self):
        gate = self.root / "release-contended"
        cache = self.root / "contended-cache"
        stamp = self.root / "contended-stamp"
        p1 = subprocess.Popen(
            [
                binary.ZIG,
                "lmod-cache",
                "--modulepath",
                str(self.modules),
                "--cache-dir",
                str(cache),
                "--timestamp",
                str(stamp),
                "--spider",
                str(self.gated_spider),
            ],
            env={
                "PATH": "/usr/bin:/bin",
                "HOME": str(self.root),
                "CONTROL_ROOT": str(self.root),
                "SPIDER_TAG": "holder",
                "SPIDER_GATE": str(gate),
            },
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: stop_proc(p1))
        self.wait_pid_file("holder.pid")

        p2 = subprocess.Popen(
            [
                binary.ZIG,
                "lmod-cache",
                "--modulepath",
                str(self.modules),
                "--cache-dir",
                str(cache),
                "--timestamp",
                str(stamp),
                "--spider",
                str(self.fast_spider),
            ],
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.root), "EB_LOCAL_LOCK_TIMEOUT_MS": "5000"},
            cwd=self.root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: stop_proc(p2))
        wait_until_holding_fd_or_exited(p2, self.root)
        self.assertIsNone(p2.poll(), "second lmod-cache did not wait on lock")

        t0 = time.monotonic()
        os.kill(p2.pid, signal.SIGTERM)
        out2, err2 = p2.communicate(timeout=5)
        self.assertEqual(p2.returncode, -signal.SIGTERM, out2 + err2)
        self.assertLess(time.monotonic() - t0, 1.0)

        gate.write_text("go\n", encoding="utf-8")
        out1, err1 = p1.communicate(timeout=10)
        self.assertEqual(p1.returncode, 0, out1 + err1)
        self.assertEqual((cache / "spiderT.lua").read_text(encoding="utf-8"), "spiderT = { writer = 'holder' }\n")


if __name__ == "__main__":
    unittest.main()
