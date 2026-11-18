#!/usr/bin/env python3
"""Concurrent eb-local invocations on the same prefix serialize with bounded locking."""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import unittest

import binary
from test_storage import StorageFixture


def _wait_for(path: Path, timeout: float = 5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return True
        time.sleep(0.02)
    return False


@unittest.skipUnless(binary.BIN, "prefix concurrency locks target the Zig build")
class PrefixConcurrency(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)

    def _gated_doubles(self, tag: str, gate: Path):
        eb_fn = rf'''
eb() {{
    python3 - "{tag}" "{gate}" "{self.root}" <<'PY'
import os, pathlib, sys, time
tag, gate, root = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
(root / f"started-{{tag}}").write_text(str(os.getpid()))
deadline = time.monotonic() + 10.0
while not gate.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
if not gate.exists():
    sys.exit(9)
(root / f"finished-{{tag}}").write_text(str(os.getpid()))
PY
}}
export -f eb
'''
        path = self.root / f"doubles-{tag}.sh"
        path.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_fn)
        return path

    def test_clean_build_output_bytes_stay_unchanged(self):
        argv, env = binary.command(self.script, ["recipe.eb"], dict(self.env))
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=False)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(run.stderr, b"")
        self.assertIn(b"eb-local: done. To use the modules in a new shell or job:\n", run.stdout)

    def test_concurrent_builds_on_same_prefix_serialize_and_notify_stderr(self):
        gate1 = self.root / "gate1"
        gate2 = self.root / "gate2"
        d1 = self._gated_doubles("1", gate1)
        d2 = self._gated_doubles("2", gate2)

        argv1, env1 = binary.command(self.script, ["recipe1.eb"], dict(self.env, BASH_ENV=str(d1)))
        argv2, env2 = binary.command(self.script, ["recipe2.eb"], dict(self.env, BASH_ENV=str(d2)))

        with subprocess.Popen(argv1, env=env1, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as p1:
            try:
                self.assertTrue(_wait_for(self.root / "started-1"), "first build did not enter eb")
                gate2.write_text("go\n")
                with subprocess.Popen(argv2, env=env2, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as p2:
                    try:
                        time.sleep(0.35)
                        self.assertFalse((self.root / "started-2").exists(), "second build ran eb concurrently with first build")
                        self.assertIsNone(p2.poll())
                        gate1.write_text("go\n")
                        out1, err1 = p1.communicate(timeout=10)
                        out2, err2 = p2.communicate(timeout=10)
                    finally:
                        if p2.poll() is None:
                            p2.kill()
                            p2.wait()
            finally:
                if p1.poll() is None:
                    p1.kill()
                    p1.wait()

        self.assertEqual(p1.returncode, 0, out1 + err1)
        self.assertEqual(p2.returncode, 0, out2 + err2)
        self.assertIn("waiting for lock", err2)
        self.assertIn(str(self.prefix / ".eb-local" / ".lock"), err2)
        self.assertTrue((self.root / "finished-1").exists())
        self.assertTrue((self.root / "finished-2").exists())
        self.assertEqual(list(self.job.iterdir()), [])

    def test_lock_timeout_exits_2_with_clear_message(self):
        gate = self.root / "gate-to"
        d_hold = self._gated_doubles("to", gate)
        argv1, env1 = binary.command(self.script, ["recipe1.eb"], dict(self.env, BASH_ENV=str(d_hold)))
        argv2, env2 = binary.command(
            self.script,
            ["recipe2.eb"],
            dict(self.env, EB_LOCAL_LOCK_TIMEOUT_MS="200"),
        )

        with subprocess.Popen(argv1, env=env1, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as p1:
            try:
                self.assertTrue(_wait_for(self.root / "started-to"))
                r2 = subprocess.run(argv2, env=env2, cwd=self.root, capture_output=True, text=True, timeout=5)
                gate.write_text("go\n")
                out1, err1 = p1.communicate(timeout=10)
            finally:
                if p1.poll() is None:
                    p1.kill()
                    p1.wait()

        self.assertEqual(p1.returncode, 0, out1 + err1)
        self.assertEqual(r2.returncode, 2, r2.stdout + r2.stderr)
        self.assertIn("waiting for lock", r2.stderr)
        self.assertIn("timed out", r2.stderr)
        self.assertIn("200 ms", r2.stderr)
        self.assertIn(str(self.prefix / ".eb-local" / ".lock"), r2.stderr)

    def test_sigkill_and_sigterm_release_prefix_lock_for_next_build(self):
        gate = self.root / "never"
        d_hold = self._gated_doubles("hold", gate)
        argv1, env1 = binary.command(self.script, ["recipe1.eb"], dict(self.env, BASH_ENV=str(d_hold)))

        with subprocess.Popen(argv1, env=env1, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as p1:
            try:
                self.assertTrue(_wait_for(self.root / "started-hold"), "holder did not enter eb")
                p1.kill()
                p1.wait(timeout=5)
            finally:
                if p1.poll() is None:
                    p1.kill()
                    p1.wait()

        argv2, env2 = binary.command(self.script, ["recipe2.eb"], dict(self.env))
        after_kill = subprocess.run(argv2, env=env2, cwd=self.root, capture_output=True, text=True, timeout=5)
        self.assertEqual(after_kill.returncode, 0, after_kill.stdout + after_kill.stderr)

        for w in list(self.job.iterdir()):
            shutil.rmtree(w)
        (self.root / "started-hold").unlink(missing_ok=True)
        with subprocess.Popen(argv1, env=env1, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as p_term:
            try:
                self.assertTrue(_wait_for(self.root / "started-hold"), "holder did not enter eb")
                p_term.send_signal(signal.SIGTERM)
                p_term.wait(timeout=5)
            finally:
                if p_term.poll() is None:
                    p_term.kill()
                    p_term.wait()

        after_term = subprocess.run(argv2, env=env2, cwd=self.root, capture_output=True, text=True, timeout=5)
        self.assertEqual(after_term.returncode, 0, after_term.stdout + after_term.stderr)

    def test_unsupported_flock_warns_and_continues_unlocked(self):
        for code, msg in (
            ("ENOLCK", "No locks available"),
            ("ENOTSUP", "Operation not supported"),
            ("EOPNOTSUPP", "Operation not supported"),
        ):
            argv_u, env_u = binary.command(self.script, ["recipe.eb"], dict(self.env))
            env_u["EB_LOCAL_TEST_FLOCK_ERRNO"] = code
            run = subprocess.run(argv_u, env=env_u, cwd=self.root, capture_output=True, text=True, timeout=5)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn(msg, run.stderr)
            self.assertIn("continuing unlocked", run.stderr)
            self.assertEqual(run.stderr.count("continuing unlocked"), 1)
            self.assertIn("eb-local: done.", run.stdout)


if __name__ == "__main__":
    unittest.main()
