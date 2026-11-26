#!/usr/bin/env python3
"""Atomic pre-backdated timestamp publication in `eb-local lmod-cache`."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import unittest

import binary


@unittest.skipUnless(binary.ZIG, "lmod-cache is a feature of the Zig build")
class LmodCacheAtomicStamp(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-lmod-stamp-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.modules = self.root / "modules"
        self.modules.mkdir()

    def test_refresh_never_exposes_timestamp_at_or_newer_than_cache(self):
        spider = self.root / "payload-spider"
        payload = "-- spider payload\n" + ("entry = 1\n" * 2048)
        spider.write_text(f"#!/bin/sh\ncat <<'EOF'\n{payload}EOF\n", encoding="utf-8")
        spider.chmod(spider.stat().st_mode | stat.S_IEXEC)

        cache = self.root / "cache"
        cache_file = cache / "spiderT.lua"
        env = {"PATH": "/usr/bin:/bin", "HOME": str(self.root)}
        rounds = 60
        stamps = [self.root / f"system-{idx}.txt" for idx in range(rounds)]
        for sp in stamps:
            sp.write_bytes(b"seed\n")
            os.utime(sp, ns=(1_000_000_000, 1_000_000_000))

        seed_stamp = self.root / "seed.txt"
        seed = subprocess.run(
            [
                binary.ZIG,
                "lmod-cache",
                "--modulepath",
                str(self.modules),
                "--cache-dir",
                str(cache),
                "--timestamp",
                str(seed_stamp),
                "--spider",
                str(spider),
            ],
            env=env,
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(seed.returncode, 0, seed.stderr)

        current_stamp = [stamps[0]]
        stale_observations = []
        stop_reader = threading.Event()
        ready_count = [0]
        ready_lock = threading.Lock()
        all_ready = threading.Event()

        def reader():
            with ready_lock:
                ready_count[0] += 1
                if ready_count[0] == 2:
                    all_ready.set()
            while not stop_reader.is_set():
                sp = current_stamp[0]
                try:
                    st_stamp = sp.stat()
                    st_cache = cache_file.stat()
                except FileNotFoundError:
                    continue
                if st_stamp.st_mtime_ns >= st_cache.st_mtime_ns:
                    stale_observations.append((sp.name, st_stamp.st_mtime_ns, st_cache.st_mtime_ns))

        threads = [threading.Thread(target=reader, daemon=True) for _ in range(2)]
        for thread in threads:
            thread.start()
        self.assertTrue(all_ready.wait(timeout=5.0))
        try:
            for idx, sp in enumerate(stamps):
                current_stamp[0] = sp
                got = subprocess.run(
                    [
                        binary.ZIG,
                        "lmod-cache",
                        "--modulepath",
                        str(self.modules),
                        "--cache-dir",
                        str(cache),
                        "--timestamp",
                        str(sp),
                        "--spider",
                        str(spider),
                    ],
                    env=env,
                    cwd=self.root,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(got.returncode, 0, f"iter={idx} err={got.stderr}")
        finally:
            stop_reader.set()
            for thread in threads:
                thread.join(timeout=2.0)

        self.assertEqual(stale_observations, [], f"observed stamp >= spiderT.lua: {stale_observations[:3]}")
        for sp in stamps:
            self.assertLess(sp.stat().st_mtime_ns, cache_file.stat().st_mtime_ns)
        self.assertFalse(any(p.name.startswith(".system-") for p in self.root.iterdir()))


if __name__ == "__main__":
    unittest.main()
