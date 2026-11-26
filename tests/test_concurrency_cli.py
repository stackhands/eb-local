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


@unittest.skipUnless(binary.ZIG, "prefix concurrency locks target the Zig build")
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

    def test_clean_workspaces_skips_active_build_and_removes_killed_workspace(self):
        import json

        gate = self.root / "gate-ws"
        d_hold = self._gated_doubles("ws", gate)
        argv1, env1 = binary.command(self.script, ["recipe.eb"], dict(self.env, BASH_ENV=str(d_hold)))
        other_prefix = self.root / "durable" / "other-prefix"
        other_prefix.mkdir(parents=True)

        with subprocess.Popen(argv1, env=env1, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as p1:
            try:
                self.assertTrue(_wait_for(self.root / "started-ws"), "build did not enter eb")
                work_dirs = list(self.job.iterdir())
                self.assertEqual(len(work_dirs), 1)
                active_ws = work_dirs[0]

                argv_c, env_c = binary.command(
                    self.script,
                    ["clean", "--workspaces", "--no-logs", "--json"],
                    dict(self.env, EB_LOCAL_PREFIX=str(other_prefix)),
                )
                clean_live = subprocess.run(argv_c, env=env_c, cwd=self.root, capture_output=True, text=True, timeout=5)
                self.assertEqual(clean_live.returncode, 0, clean_live.stdout + clean_live.stderr)
                doc_live = json.loads(clean_live.stdout)
                self.assertEqual(doc_live["removed_workspaces"], 0, doc_live)
                self.assertTrue(active_ws.is_dir(), "clean deleted an active build workspace")

                p1.kill()
                p1.wait(timeout=5)
            finally:
                if p1.poll() is None:
                    p1.kill()
                    p1.wait()

        argv_c2, env_c2 = binary.command(
            self.script,
            ["clean", "--workspaces", "--no-logs", "--json"],
            dict(self.env),
        )
        clean_dead = subprocess.run(argv_c2, env=env_c2, cwd=self.root, capture_output=True, text=True, timeout=5)
        self.assertEqual(clean_dead.returncode, 0, clean_dead.stdout + clean_dead.stderr)
        doc_dead = json.loads(clean_dead.stdout)
        self.assertEqual(doc_dead["removed_workspaces"], 1, doc_dead)
        self.assertEqual(list(self.job.iterdir()), [])

    def test_clean_sources_waits_for_running_build_on_same_prefix(self):
        gate = self.root / "gate-src"
        eb_src = rf'''
eb() {{
    python3 - "{gate}" "{self.root}" <<'PY'
import os, pathlib, sys, time
gate, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
src = pathlib.Path(os.environ["EASYBUILD_SOURCEPATH"]) / "pkg.tar.gz"
src.write_text("tarball\n")
(root / "started-src").write_text("1")
deadline = time.monotonic() + 10.0
while not gate.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
if not gate.exists() or not src.exists():
    sys.exit(7)
PY
}}
export -f eb
'''
        doubles = self.root / "doubles-src.sh"
        doubles.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_src)
        argv_b, env_b = binary.command(self.script, ["recipe.eb"], dict(self.env, BASH_ENV=str(doubles)))
        argv_c, env_c = binary.command(
            self.script,
            ["clean", "--sources", "--no-logs", "--delete"],
            dict(self.env, SLURM_JOB_ID=""),
        )

        with subprocess.Popen(argv_b, env=env_b, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as pb:
            try:
                self.assertTrue(_wait_for(self.root / "started-src"))
                with subprocess.Popen(argv_c, env=env_c, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as pc:
                    try:
                        time.sleep(0.35)
                        self.assertIsNone(pc.poll(), "clean --sources ran while build held prefix lock")
                        self.assertTrue((self.prefix / ".eb-local" / "sources" / "pkg.tar.gz").exists())
                        gate.write_text("go\n")
                        out_b, err_b = pb.communicate(timeout=10)
                        out_c, err_c = pc.communicate(timeout=10)
                    finally:
                        if pc.poll() is None:
                            pc.kill()
                            pc.wait()
            finally:
                if pb.poll() is None:
                    pb.kill()
                    pb.wait()

        self.assertEqual(pb.returncode, 0, out_b + err_b)
        self.assertEqual(pc.returncode, 0, out_c + err_c)
        self.assertFalse((self.prefix / ".eb-local" / "sources" / "pkg.tar.gz").exists())

    def test_uninstall_waits_for_running_build_and_releases_lock_on_early_exit(self):
        tree = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        inst = tree / "software" / "demo" / "1.0"
        mod = tree / "modules" / "all" / "demo" / "1.0.lua"
        inst.mkdir(parents=True)
        mod.parent.mkdir(parents=True)
        mod.write_text("-- demo\n")

        gate = self.root / "gate-un"
        eb_un = rf'''
eb() {{
    python3 - "{gate}" "{self.root}" "{inst}" <<'PY'
import pathlib, sys, time
gate, root, inst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
(root / "started-un").write_text("1")
deadline = time.monotonic() + 10.0
while not gate.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
if not gate.exists() or not inst.exists():
    sys.exit(8)
PY
}}
export -f eb
'''
        doubles = self.root / "doubles-un.sh"
        doubles.write_text((self.root / "doubles.sh").read_text() + "\n" + eb_un)
        argv_b, env_b = binary.command(self.script, ["recipe.eb"], dict(self.env, BASH_ENV=str(doubles)))
        argv_u, env_u = binary.command(
            self.script,
            ["uninstall", "demo/1.0", "--delete"],
            dict(self.env, SLURM_JOB_ID="", PATH="/usr/bin:/bin"),
        )

        with subprocess.Popen(argv_b, env=env_b, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as pb:
            try:
                self.assertTrue(_wait_for(self.root / "started-un"))
                with subprocess.Popen(argv_u, env=env_u, cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as pu:
                    try:
                        time.sleep(0.35)
                        self.assertIsNone(pu.poll(), "uninstall ran while build held prefix lock")
                        self.assertTrue(inst.exists())
                        gate.write_text("go\n")
                        out_b, err_b = pb.communicate(timeout=10)
                        out_u, err_u = pu.communicate(timeout=10)
                    finally:
                        if pu.poll() is None:
                            pu.kill()
                            pu.wait()
            finally:
                if pb.poll() is None:
                    pb.kill()
                    pb.wait()

        self.assertEqual(pb.returncode, 0, out_b + err_b)
        self.assertEqual(pu.returncode, 0, out_u + err_u)
        self.assertFalse(inst.exists())

        dep_inst = tree / "software" / "app" / "1.0"
        dep_mod = tree / "modules" / "all" / "app" / "1.0.lua"
        base_inst = tree / "software" / "base" / "1.0"
        base_mod = tree / "modules" / "all" / "base" / "1.0.lua"
        dep_inst.mkdir(parents=True)
        base_inst.mkdir(parents=True)
        dep_mod.parent.mkdir(parents=True)
        base_mod.parent.mkdir(parents=True)
        dep_mod.write_text('load("base/1.0")\n')
        base_mod.write_text("-- base\n")

        argv_dep, env_dep = binary.command(
            self.script,
            ["uninstall", "base/1.0", "--delete"],
            dict(self.env, SLURM_JOB_ID="", PATH="/usr/bin:/bin"),
        )
        r_dep = subprocess.run(argv_dep, env=env_dep, cwd=self.root, capture_output=True, text=True, timeout=5)
        self.assertEqual(r_dep.returncode, 2, r_dep.stdout + r_dep.stderr)

        argv_nodel, env_nodel = binary.command(
            self.script,
            ["uninstall", "app/1.0"],
            dict(self.env, SLURM_JOB_ID="", PATH="/usr/bin:/bin"),
        )
        r_nodel = subprocess.run(argv_nodel, env=env_nodel, cwd=self.root, capture_output=True, text=True, timeout=5)
        self.assertEqual(r_nodel.returncode, 1, r_nodel.stdout + r_nodel.stderr)

        argv_b2, env_b2 = binary.command(self.script, ["recipe.eb"], dict(self.env))
        r_b2 = subprocess.run(argv_b2, env=env_b2, cwd=self.root, capture_output=True, text=True, timeout=5)
        self.assertEqual(r_b2.returncode, 0, r_b2.stdout + r_b2.stderr)


if __name__ == "__main__":
    unittest.main()
