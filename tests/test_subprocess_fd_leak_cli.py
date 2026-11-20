#!/usr/bin/env python3
"""No leaked `/dev/null` descriptors in `doctor --workspace` or `lmod-cache`."""

import fcntl
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import unittest

import binary

F_SETPIPE_SZ = 1031

FD_RECORDER = r'''#!/usr/bin/env python3
import json, os, sys

tag = sys.argv[1]
names = os.listdir("/proc/self/fd")
open_fds = sorted(int(n) for n in names if os.path.lexists(f"/proc/self/fd/{n}"))
out = os.path.join(os.environ["FD_RECORD_DIR"], f"{tag}.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump(open_fds, fh)
'''


@unittest.skipUnless(binary.BIN, "subprocess descriptor isolation belongs to the Zig binary")
class SubprocessNullFdLeakCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-subproc-fd-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.records = self.root / "records"
        self.records.mkdir()
        self.bins = self.root / "bins"
        self.bins.mkdir()

        recorder = self.root / "fd-recorder.py"
        recorder.write_text(FD_RECORDER, encoding="utf-8")
        recorder.chmod(0o755)
        self.recorder = recorder

    def base_env(self, **extra):
        env = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith("EB_LOCAL_") and not k.startswith("EESSI_")
        }
        env.update(
            HOME=str(self.root),
            FD_RECORD_DIR=str(self.records),
            PATH=f"{self.bins}:/usr/bin:/bin",
            SLURM_JOB_ID="",
        )
        env.update(extra)
        return env

    @staticmethod
    def snapshot_fds(pid: int) -> dict[int, str]:
        out: dict[int, str] = {}
        fd_dir = f"/proc/{pid}/fd"
        for name in os.listdir(fd_dir):
            try:
                out[int(name)] = os.readlink(f"{fd_dir}/{name}")
            except OSError:
                continue
        return out

    def test_doctor_workspace_probe_leaves_no_null_fd_open(self):
        ws = self.root / "workspace"
        ws.mkdir()
        os.utime(ws, ns=(0, 0))

        rfd, wfd = os.pipe()
        self.addCleanup(lambda: os.close(rfd) if rfd >= 0 else None)
        try:
            fcntl.fcntl(wfd, F_SETPIPE_SZ, 4096)
        except OSError:
            pass
        os.set_blocking(wfd, False)
        chunk = b"x" * 4096
        while True:
            try:
                os.write(wfd, chunk)
            except BlockingIOError:
                break
        os.set_blocking(wfd, True)

        proc = subprocess.Popen(
            [binary.BIN, "doctor", "--workspace", str(ws)],
            env=self.base_env(),
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=wfd,
            stderr=subprocess.PIPE,
        )
        os.close(wfd)

        try:
            poller = select.poll()
            deadline = time.monotonic() + 5.0
            open_fds: dict[int, str] = {}
            while True:
                if proc.poll() is not None:
                    self.fail(f"doctor exited before blocking on full stdout pipe: rc={proc.returncode}")
                st = ws.stat()
                if st.st_mtime_ns != 0 and not any(ws.iterdir()):
                    open_fds = self.snapshot_fds(proc.pid)
                    if str(ws) not in open_fds.values():
                        break
                if time.monotonic() >= deadline:
                    self.fail("timed out waiting for workspace probe completion")
                poller.poll(2)

            extra_fds = {fd: target for fd, target in open_fds.items() if fd > 2}
            self.assertEqual(extra_fds, {}, f"leaked extra descriptors: {open_fds}")
        finally:
            os.set_blocking(rfd, False)
            while True:
                try:
                    data = os.read(rfd, 65536)
                except BlockingIOError:
                    if proc.poll() is not None:
                        break
                    select.poll().poll(2)
                    continue
                if not data:
                    break
            os.close(rfd)
            rfd = -1
            if proc.stderr is not None:
                proc.stderr.read()
                proc.stderr.close()
            proc.wait(timeout=5)

    def test_lmod_cache_spider_and_verify_module_inherit_only_stdio(self):
        spider = self.root / "spider"
        spider.write_text(
            f"#!/bin/sh\npython3 '{self.recorder}' spider\nprintf 'spiderT = {{}}\\n'\n",
            encoding="utf-8",
        )
        spider.chmod(0o755)

        mod = self.bins / "module"
        mod.write_text(
            f"#!/bin/sh\npython3 '{self.recorder}' module\nexit 7\n",
            encoding="utf-8",
        )
        mod.chmod(0o755)

        modules = self.root / "modules"
        modules.mkdir()
        cache = self.root / "cache"
        stamp = self.root / "system.txt"

        run = subprocess.run(
            [
                binary.BIN,
                "lmod-cache",
                "--verify",
                "--modulepath",
                str(modules),
                "--cache-dir",
                str(cache),
                "--timestamp",
                str(stamp),
                "--spider",
                str(spider),
            ],
            env=self.base_env(),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertNotEqual(run.returncode, 0)
        spider_fds = json.loads((self.records / "spider.json").read_text(encoding="utf-8"))
        module_fds = json.loads((self.records / "module.json").read_text(encoding="utf-8"))
        self.assertEqual(spider_fds, [0, 1, 2])
        self.assertEqual(module_fds, [0, 1, 2])

    def test_lmod_cache_prefix_update_cmd_inherits_only_stdio(self):
        prefix = self.root / "prefix"
        (prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "generic" / "modules" / "all").mkdir(parents=True)
        update = self.root / "update-cmd"
        update.write_text(
            f"#!/bin/sh\npython3 '{self.recorder}' update\nexit 5\n",
            encoding="utf-8",
        )
        update.chmod(0o755)

        run = subprocess.run(
            [
                binary.BIN,
                "lmod-cache",
                "--prefix",
                str(prefix),
                "--eessi-version",
                "2026.06",
                "--update-cmd",
                str(update),
            ],
            env=self.base_env(),
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(run.returncode, 5, run.stdout + run.stderr)
        update_fds = json.loads((self.records / "update.json").read_text(encoding="utf-8"))
        self.assertEqual(update_fds, [0, 1, 2])


if __name__ == "__main__":
    unittest.main()
