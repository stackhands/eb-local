#!/usr/bin/env python3
"""Signal cancellation and workspace cleanup while waiting on `.eb-local/.lock`."""
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import time
import unittest

import binary
from test_storage import StorageFixture


def stop_proc(proc):
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    if proc.stdout:
        proc.stdout.close()
    if proc.stderr:
        proc.stderr.close()


def wait_signal_not_pending(pid, sig, timeout=5.0):
    bit = 1 << (int(sig) - 1)
    status_path = Path(f"/proc/{pid}/status")
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            text = status_path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return
        pending = 0
        for line in text.splitlines():
            if line.startswith(("SigPnd:", "ShdPnd:")):
                pending |= int(line.split(":", 1)[1].strip(), 16)
        if (pending & bit) == 0:
            return
        time.sleep(0.005)
    raise AssertionError(f"signal {sig} remained pending on pid {pid}")


@unittest.skipUnless(binary.ZIG, "prefix lock cancellation targets the Zig build")
class PrefixLockSignalCancel(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)

    def hold_prefix_lock(self):
        eb_dir = self.prefix / ".eb-local"
        eb_dir.mkdir(parents=True, exist_ok=True)
        fd = os.open(eb_dir / ".lock", os.O_RDWR | os.O_CREAT, 0o666)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd

    def wait_until_waiting_on_lock(self, proc):
        line = proc.stderr.readline()
        self.assertIn("waiting for lock", line, f"unexpected stderr line: {line!r}")
        return line

    def test_signals_during_contended_prefix_lock_wait_abort_clean_workspace_and_reraise(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig.name):
                lock_fd = self.hold_prefix_lock()
                try:
                    argv, env = binary.command(
                        self.script,
                        ["recipe.eb"],
                        dict(self.env, EB_LOCAL_LOCK_TIMEOUT_MS="2000"),
                    )
                    proc = subprocess.Popen(
                        argv,
                        env=env,
                        cwd=self.root,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    self.addCleanup(lambda p=proc: stop_proc(p))
                    first_err = self.wait_until_waiting_on_lock(proc)
                    os.kill(proc.pid, sig)
                    out, rest_err = proc.communicate(timeout=5)
                    err = first_err + rest_err
                    self.assertEqual(proc.returncode, -sig, f"rc={proc.returncode}\nout={out}\nerr={err}")
                    self.assertNotIn("timed out", err)
                    self.assertNotIn("build workspace kept", err)
                    self.assertEqual(list(self.job.iterdir()), [])
                finally:
                    os.close(lock_fd)

    def test_ignored_sighup_during_prefix_lock_wait_continues_once_unlocked(self):
        lock_fd = self.hold_prefix_lock()
        closed = False
        try:
            argv, env = binary.command(
                self.script,
                ["recipe.eb"],
                dict(self.env, EB_LOCAL_LOCK_TIMEOUT_MS="5000"),
            )
            proc = subprocess.Popen(
                argv,
                env=env,
                cwd=self.root,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                preexec_fn=lambda: signal.signal(signal.SIGHUP, signal.SIG_IGN),
            )
            self.addCleanup(lambda p=proc: stop_proc(p))
            first_err = self.wait_until_waiting_on_lock(proc)
            os.kill(proc.pid, signal.SIGHUP)
            wait_signal_not_pending(proc.pid, signal.SIGHUP)
            self.assertIsNone(proc.poll())
            os.close(lock_fd)
            closed = True
            out, rest_err = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, out + first_err + rest_err)
            self.assertEqual(list(self.job.iterdir()), [])
        finally:
            if not closed:
                os.close(lock_fd)


if __name__ == "__main__":
    unittest.main()
