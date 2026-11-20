#!/usr/bin/env python3
"""Signal forwarding to the child process group across `Guard.run` call sites."""

import os
from pathlib import Path
import pty
import signal
import subprocess
import time
import unittest

import binary
from test_storage import StorageFixture

COOP_TREE = r'''
import os, signal, sys, time

root = os.environ["CONTROL_ROOT"]
tag = os.environ.get("TREE_TAG", "eb")

def write_atomic(path, text):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)

rfd, wfd = os.pipe()
worker = os.fork()
if worker == 0:
    os.close(rfd)
    got = []
    def on_sig(sig, _frame):
        got.append(signal.Signals(sig).name)
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        if signal.getsignal(s) != signal.SIG_IGN:
            signal.signal(s, on_sig)
    write_atomic(os.path.join(root, f"{tag}.worker.pgid"), str(os.getpgrp()))
    write_atomic(os.path.join(root, f"{tag}.worker.pid"), str(os.getpid()))
    os.close(wfd)
    deadline = time.monotonic() + float(os.environ.get("WORKER_WAIT", "1.2"))
    while not got and time.monotonic() < deadline:
        time.sleep(0.01)
    write_atomic(os.path.join(root, f"{tag}.worker.signals"), " ".join(got))
    os._exit(0)

os.close(wfd)
os.read(rfd, 1)
os.close(rfd)

got_parent = []
def on_parent(sig, _frame):
    got_parent.append(signal.Signals(sig).name)
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    if signal.getsignal(s) != signal.SIG_IGN:
        signal.signal(s, on_parent)

write_atomic(os.path.join(root, f"{tag}.pid"), str(os.getpid()))

while True:
    try:
        os.waitpid(worker, 0)
        break
    except InterruptedError:
        continue

write_atomic(os.path.join(root, f"{tag}.signals"), " ".join(got_parent))
sys.exit(15 if (got_parent and got_parent[0] == "SIGTERM") else 1)
'''


def wait_file(path: Path, timeout: float = 10.0) -> str:
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {path}")
        time.sleep(0.005)
    return path.read_text(encoding="utf-8")


@unittest.skipUnless(binary.BIN, "process-group signal forwarding belongs to the Zig binary")
class ChildPgroupForwardCli(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)
        (self.root / "coop-tree.py").write_text(COOP_TREE, encoding="utf-8")
        self.bins = self.root / "tree-bin"
        self.bins.mkdir()
        for tool in ("eb", "sbatch", "rtrash"):
            wrapper = self.bins / tool
            wrapper.write_text(
                f'#!/bin/bash\nexport TREE_TAG={tool}\nexec python3 "$CONTROL_ROOT/coop-tree.py" "$@"\n',
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
        no_eb_fn = self.root / "doubles-nofn.sh"
        no_eb_fn.write_text((self.root / "doubles.sh").read_text() + "\nunset -f eb\n", encoding="utf-8")
        self.no_eb_fn = no_eb_fn

    @staticmethod
    def kill_if_alive(pid: int):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass

    @staticmethod
    def stop_popen(proc: subprocess.Popen):
        if proc.poll() is None:
            proc.kill()
        try:
            proc.communicate(timeout=2)
        except Exception:
            pass

    def clean_markers(self, tag: str):
        for suffix in ("pid", "signals", "worker.pid", "worker.pgid", "worker.signals"):
            p = self.root / f"{tag}.{suffix}"
            if p.exists():
                p.unlink()

    def test_non_tty_signals_reach_build_process_group_and_isolate_caller_group(self):
        argv, env = binary.command(
            self.script,
            ["recipe.eb"],
            dict(self.env, BASH_ENV=str(self.no_eb_fn)),
        )
        env["PATH"] = f"{self.bins}:{env['PATH']}"

        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig.name):
                self.clean_markers("eb")
                proc = subprocess.Popen(
                    argv,
                    env=env,
                    cwd=self.root,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.addCleanup(self.stop_popen, proc)
                eb_pid = int(wait_file(self.root / "eb.pid"))
                worker_pid = int(wait_file(self.root / "eb.worker.pid"))
                self.addCleanup(self.kill_if_alive, worker_pid)
                self.addCleanup(self.kill_if_alive, eb_pid)
                worker_pgid = int(wait_file(self.root / "eb.worker.pgid"))

                os.kill(proc.pid, sig)
                out, err = proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, -sig, out + err)
                self.assertEqual(wait_file(self.root / "eb.worker.signals"), sig.name)
                self.assertEqual(worker_pgid, eb_pid)
                self.assertNotEqual(worker_pgid, os.getpgrp())
                with self.assertRaises(ProcessLookupError):
                    os.kill(worker_pid, 0)

    def test_non_tty_signals_reach_eb_submit_and_clean_process_groups(self):
        eessi_init = self.root / "repo" / "versions" / "2026.06" / "init" / "lmod" / "bash"
        eessi_init.parent.mkdir(parents=True, exist_ok=True)
        eessi_init.write_text(
            "module() { export EASYBUILD_INSTALLPATH=\"${EESSI_USER_INSTALL:-$HOME/eessi}/versions/2026.06\"; }\n",
            encoding="utf-8",
        )
        sources = self.prefix / ".eb-local" / "sources" / "pkg"
        sources.mkdir(parents=True, exist_ok=True)
        (sources / "src.tar.gz").write_text("archive\n", encoding="utf-8")

        submit_site = self.root / "submit-site.toml"
        submit_site.write_text(
            "[storage]\n"
            f'node_local_root = "{self.nodes}"\n'
            'node_local_fstype = "xfs"\n'
            "[build.node_types]\n"
            'cpu = "-p cpu -n 4 -t 01:00:00"\n',
            encoding="utf-8",
        )
        submit_site.chmod(0o600)

        cases = [
            (
                "eb",
                ["eb", "zlib.eb"],
                dict(
                    self.env,
                    SLURM_JOB_ID="",
                    EESSI_CVMFS_REPO=str(self.root / "repo"),
                    EESSI_USER_INSTALL=str(self.root / "user-eessi"),
                ),
            ),
            (
                "sbatch",
                ["submit", "recipe.eb"],
                dict(self.env, SLURM_JOB_ID="", EB_LOCAL_CONFIG=str(submit_site)),
            ),
            (
                "rtrash",
                ["clean", "--no-logs", "--sources"],
                dict(self.env, SLURM_JOB_ID=""),
            ),
        ]

        for tag, args, case_env in cases:
            with self.subTest(command=args[0]):
                self.clean_markers(tag)
                argv, env = binary.command(self.script, args, case_env)
                env["PATH"] = f"{self.bins}:{env['PATH']}"
                proc = subprocess.Popen(
                    argv,
                    env=env,
                    cwd=self.root,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                self.addCleanup(self.stop_popen, proc)
                child_pid = int(wait_file(self.root / f"{tag}.pid"))
                worker_pid = int(wait_file(self.root / f"{tag}.worker.pid"))
                self.addCleanup(self.kill_if_alive, worker_pid)
                self.addCleanup(self.kill_if_alive, child_pid)

                os.kill(proc.pid, signal.SIGTERM)
                out, err = proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, -signal.SIGTERM, out + err)
                self.assertEqual(wait_file(self.root / f"{tag}.worker.signals"), "SIGTERM")
                with self.assertRaises(ProcessLookupError):
                    os.kill(worker_pid, 0)

    def test_foreground_pty_external_sigterm_and_ctrl_c_each_deliver_once(self):
        argv, env = binary.command(
            self.script,
            ["recipe.eb"],
            dict(self.env, BASH_ENV=str(self.no_eb_fn)),
        )
        env["PATH"] = f"{self.bins}:{env['PATH']}"

        for mode in ("external_term", "ctrl_c"):
            with self.subTest(mode=mode):
                self.clean_markers("eb")
                pid, master = pty.fork()
                if pid == 0:
                    os.chdir(self.root)
                    os.execve(argv[0], argv, env)
                self.addCleanup(os.close, master)
                eb_pid = int(wait_file(self.root / "eb.pid"))
                worker_pid = int(wait_file(self.root / "eb.worker.pid"))
                self.addCleanup(self.kill_if_alive, worker_pid)
                self.addCleanup(self.kill_if_alive, eb_pid)

                if mode == "external_term":
                    os.kill(pid, signal.SIGTERM)
                    want_sig = signal.SIGTERM
                else:
                    os.write(master, b"\x03")
                    want_sig = signal.SIGINT

                deadline = time.monotonic() + 10.0
                while True:
                    self.assertLess(time.monotonic(), deadline)
                    try:
                        chunk = os.read(master, 4096)
                    except OSError:
                        break
                    if not chunk:
                        break
                _, status = os.waitpid(pid, 0)
                self.assertTrue(os.WIFSIGNALED(status), status)
                self.assertEqual(os.WTERMSIG(status), want_sig)
                self.assertEqual(wait_file(self.root / "eb.worker.signals"), want_sig.name)
                self.assertEqual(wait_file(self.root / "eb.signals"), want_sig.name)


if __name__ == "__main__":
    unittest.main()
