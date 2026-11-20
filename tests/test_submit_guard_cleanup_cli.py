#!/usr/bin/env python3
"""Signal guard scope and unsubmitted script cleanup in `eb-local submit`."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import unittest

import binary
from test_storage import StorageFixture

FAKE_SBATCH = r'''#!/usr/bin/env python3
import os, select, signal, sys

root = os.environ["CONTROL_ROOT"]
mode = os.environ.get("SBATCH_MODE", "block_second")
calls_path = os.path.join(root, "sbatch.calls")
existing = []
if os.path.exists(calls_path):
    with open(calls_path, "r", encoding="utf-8") as handle:
        existing = [line for line in handle.read().splitlines() if line]
call_no = len(existing) + 1
with open(calls_path, "a", encoding="utf-8") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")

if mode == "signal_on_first_success" and call_no == 1:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    sys.stdout.write("Submitted batch job 101\n")
    sys.stdout.flush()
    os.kill(os.getppid(), signal.SIGTERM)
    sys.exit(0)

if call_no == 1:
    sys.stdout.write("Submitted batch job 101\n")
    sys.stdout.flush()
    sys.exit(0)

rfd, wfd = os.pipe()
os.set_blocking(wfd, False)
signal.set_wakeup_fd(wfd, warn_on_full_buffer=False)
got = []

def note(sig, _frame):
    got.append(sig)

for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    if signal.getsignal(sig) != signal.SIG_IGN:
        signal.signal(sig, note)

tmp = os.path.join(root, f".sbatch.pid.{os.getpid()}.tmp")
with open(tmp, "w", encoding="utf-8") as handle:
    handle.write(str(os.getpid()))
os.replace(tmp, os.path.join(root, "sbatch.pid"))

while not got:
    ready, _, _ = select.select([rfd], [], [], 20.0)
    if not ready:
        break
    try:
        os.read(rfd, 64)
    except OSError:
        pass

sys.exit(1)
'''


def stop_proc(proc):
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    if proc.stdout:
        proc.stdout.close()
    if proc.stderr:
        proc.stderr.close()


def kill_quiet(pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


@unittest.skipUnless(binary.BIN, "submit signal cleanup targets the Zig build")
class SubmitGuardCleanup(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)
        self.programs = self.root / "submit-bin"
        self.programs.mkdir()
        sbatch = self.programs / "sbatch"
        sbatch.write_text(FAKE_SBATCH, encoding="utf-8")
        sbatch.chmod(0o755)
        self.site_toml = self.root / "submit-site.toml"
        self.site_toml.write_text(
            "[storage]\n"
            f'node_local_root = "{self.nodes}"\n'
            'node_local_fstype = "xfs"\n'
            f'shared_scratch = ["/scratch", "{self.nodes.parent / "shared"}"]\n'
            "[build.node_types]\n"
            'cpu = "-p cpu -n 4"\n'
            'gpu = "-p gpu -n 4"\n'
            'highmem = "-p highmem -n 8"\n',
            encoding="utf-8",
        )
        self.site_toml.chmod(0o644)

    def wait_pid_file(self, name):
        path = self.root / name
        deadline = time.monotonic() + 15.0
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, f"{name} did not appear")
            time.sleep(0.005)
        pid = int(path.read_text(encoding="utf-8").strip())
        self.addCleanup(lambda: kill_quiet(pid))
        return pid

    def reset_run_state(self):
        (self.root / "sbatch.pid").unlink(missing_ok=True)
        (self.root / "sbatch.calls").unlink(missing_ok=True)
        jobs_dir = self.prefix / ".eb-local" / "jobs"
        if jobs_dir.exists():
            shutil.rmtree(jobs_dir)

    def test_interrupted_sbatch_unlinks_unsubmitted_script_and_preserves_submitted(self):
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig.name):
                self.reset_run_state()
                argv, env = binary.command(
                    self.script,
                    ["submit", "recipe.eb"],
                    dict(
                        self.env,
                        EB_LOCAL_CONFIG=str(self.site_toml),
                        SLURM_JOB_ID="",
                        CONTROL_ROOT=str(self.root),
                    ),
                )
                env["PATH"] = f"{self.programs}:/usr/bin:/bin"
                proc = subprocess.Popen(
                    argv,
                    env=env,
                    cwd=self.root,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.addCleanup(lambda p=proc: stop_proc(p))
                self.wait_pid_file("sbatch.pid")

                os.kill(proc.pid, sig)
                out, err = proc.communicate(timeout=10)
                self.assertEqual(proc.returncode, -sig, out + err)
                self.assertNotIn("sbatch refused", err)
                self.assertNotIn("each job writes", out)

                calls = (self.root / "sbatch.calls").read_text(encoding="utf-8").splitlines()
                self.assertEqual(len(calls), 2, calls)
                jobs_dir = self.prefix / ".eb-local" / "jobs"
                kept = sorted(p.name for p in jobs_dir.iterdir())
                self.assertEqual(len(kept), 1, f"expected only cpu script kept, got {kept}")
                self.assertIn("-cpu-recipe.eb.sh", kept[0])

    def test_signal_after_accepted_first_target_keeps_its_script_and_skips_remaining(self):
        self.reset_run_state()
        argv, env = binary.command(
            self.script,
            ["submit", "recipe.eb"],
            dict(
                self.env,
                EB_LOCAL_CONFIG=str(self.site_toml),
                SLURM_JOB_ID="",
                CONTROL_ROOT=str(self.root),
                SBATCH_MODE="signal_on_first_success",
            ),
        )
        env["PATH"] = f"{self.programs}:/usr/bin:/bin"
        proc = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True, timeout=10)
        self.assertEqual(proc.returncode, -signal.SIGTERM, proc.stdout + proc.stderr)
        self.assertNotIn("each job writes", proc.stdout)
        calls = (self.root / "sbatch.calls").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(calls), 1, calls)
        jobs_dir = self.prefix / ".eb-local" / "jobs"
        kept = sorted(p.name for p in jobs_dir.iterdir())
        self.assertEqual(len(kept), 1, kept)
        self.assertIn("-cpu-recipe.eb.sh", kept[0])


if __name__ == "__main__":
    unittest.main()
