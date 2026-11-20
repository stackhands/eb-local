#!/usr/bin/env python3
"""Bounded straggler waiting and reaping on `SIGCHLD` in `Guard.run`."""

import os
from pathlib import Path
import select
import signal
import subprocess
import time
import unittest

import binary
from test_storage import StorageFixture

SECRET_VAL = "reap-secret-8d41f2b9"

LATE_WRITER = r'''
import os, select, signal, time

root = os.environ["CONTROL_ROOT"]
log = os.path.join(os.environ["EASYBUILD_TMP_LOGDIR"], "easybuild-late.log")
with open(log, "w", encoding="utf-8") as fh:
    fh.write("started\n")

def write_atomic(path, text):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)

def wait_fd(fd, events, timeout_s):
    poller = select.poll()
    poller.register(fd, events)
    deadline = time.monotonic() + timeout_s
    while True:
        rem_ms = int((deadline - time.monotonic()) * 1000)
        if rem_ms <= 0:
            return False
        try:
            ready = poller.poll(rem_ms)
        except InterruptedError:
            continue
        if ready:
            return True

release_fifo = os.path.join(root, "worker.release")
os.mkfifo(release_fifo)
ready_r, ready_w = os.pipe()
leader_alive_r, leader_alive_w = os.pipe()
worker = os.fork()
if worker == 0:
    os.close(ready_r)
    os.close(leader_alive_w)
    sig_r, sig_w = os.pipe()
    os.set_blocking(sig_w, False)
    def on_sig(_sig, _frame):
        try:
            os.write(sig_w, b"1")
        except OSError:
            pass
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, on_sig)
    gate_r = os.open(release_fifo, os.O_RDONLY | os.O_NONBLOCK)
    write_atomic(os.path.join(root, "worker.pid"), str(os.getpid()))
    os.write(ready_w, b"1")
    os.close(ready_w)

    wait_fd(sig_r, select.POLLIN, 5.0)
    os.close(sig_r)
    os.close(sig_w)

    wait_fd(leader_alive_r, select.POLLHUP | select.POLLIN, 5.0)
    os.close(leader_alive_r)
    write_atomic(os.path.join(root, "worker.reparented"), "1")

    wait_fd(gate_r, select.POLLIN, 2.0)
    os.close(gate_r)
    with open(log, "a", encoding="utf-8") as fh:
        fh.write("flushing " + os.environ["LICENCE_KEY"] + "\n")
    write_atomic(os.path.join(root, "worker.flushed"), "1")
    os._exit(0)

os.close(ready_w)
os.close(leader_alive_r)
os.read(ready_r, 1)
os.close(ready_r)

sig_r, sig_w = os.pipe()
os.set_blocking(sig_w, False)
def on_leader(_sig, _frame):
    try:
        os.write(sig_w, b"1")
    except OSError:
        pass
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, on_leader)

write_atomic(os.path.join(root, "leader.pid"), str(os.getpid()))
poller = select.poll()
poller.register(sig_r, select.POLLIN)
deadline = time.monotonic() + 5.0
while True:
    rem_ms = int((deadline - time.monotonic()) * 1000)
    if rem_ms <= 0:
        break
    try:
        if poller.poll(rem_ms):
            break
    except InterruptedError:
        continue
os.close(leader_alive_w)
os._exit(15)
'''

STRAGGLER_TREE = r'''
import os, select, signal, time

root = os.environ["CONTROL_ROOT"]
tag = os.environ["TREE_TAG"]

def write_atomic(path, text):
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)

rfd, wfd = os.pipe()
hold_r, hold_w = os.pipe()
straggler = os.fork()
if straggler == 0:
    os.close(rfd)
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, signal.SIG_IGN)
    write_atomic(os.path.join(root, f"{tag}.straggler.pid"), str(os.getpid()))
    os.write(wfd, b"1")
    os.close(wfd)
    poller = select.poll()
    poller.register(hold_r, select.POLLIN)
    poller.poll(10000)
    os._exit(0)

os.close(hold_r)
os.close(hold_w)
os.close(wfd)
os.read(rfd, 1)
os.close(rfd)

sig_r, sig_w = os.pipe()
os.set_blocking(sig_w, False)
def on_sig(_sig, _frame):
    try:
        os.write(sig_w, b"1")
    except OSError:
        pass
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, on_sig)

write_atomic(os.path.join(root, f"{tag}.leader.pid"), str(os.getpid()))
poller = select.poll()
poller.register(sig_r, select.POLLIN)
deadline = time.monotonic() + 5.0
while True:
    rem_ms = int((deadline - time.monotonic()) * 1000)
    if rem_ms <= 0:
        break
    try:
        if poller.poll(rem_ms):
            break
    except InterruptedError:
        continue
os._exit(15)
'''


def wait_file(path: Path, timeout: float = 10.0) -> str:
    poller = select.poll()
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {path}")
        poller.poll(2)
    return path.read_text(encoding="utf-8")


@unittest.skipUnless(binary.BIN, "straggler reaping belongs to the Zig binary")
class ChildPgroupReapCli(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)
        (self.root / "late-writer.py").write_text(LATE_WRITER, encoding="utf-8")
        (self.root / "straggler-tree.py").write_text(STRAGGLER_TREE, encoding="utf-8")
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

    @staticmethod
    def has_signalfd(pid: int) -> bool:
        fd_dir = f"/proc/{pid}/fd"
        try:
            names = os.listdir(fd_dir)
        except OSError:
            return False
        for name in names:
            try:
                if "signalfd" in os.readlink(f"{fd_dir}/{name}"):
                    return True
            except OSError:
                continue
        return False

    def release_fifo(self, path: Path, timeout: float = 2.0):
        poller = select.poll()
        deadline = time.monotonic() + timeout
        while True:
            try:
                wfd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
                try:
                    os.write(wfd, b"1")
                finally:
                    os.close(wfd)
                return
            except OSError:
                if time.monotonic() >= deadline:
                    return
                poller.poll(2)

    def test_cooperative_descendant_wakes_on_sigchld_before_secret_redaction(self):
        late_bin = self.root / "late-bin"
        late_bin.mkdir()
        eb = late_bin / "eb"
        eb.write_text('#!/bin/bash\nexec python3 "$CONTROL_ROOT/late-writer.py" "$@"\n', encoding="utf-8")
        eb.chmod(0o755)

        argv, env = binary.command(
            self.script,
            ["recipe.eb"],
            dict(
                self.env,
                BASH_ENV=str(self.no_eb_fn),
                LICENCE_SRC=SECRET_VAL,
                EB_LOCAL_SECRET_LICENCE_KEY="env:LICENCE_SRC",
            ),
        )
        env["PATH"] = f"{late_bin}:{env['PATH']}"

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
        leader_pid = int(wait_file(self.root / "leader.pid"))
        worker_pid = int(wait_file(self.root / "worker.pid"))
        self.addCleanup(self.kill_if_alive, worker_pid)
        self.addCleanup(self.kill_if_alive, leader_pid)

        t0 = time.monotonic()
        os.kill(proc.pid, signal.SIGTERM)
        wait_file(self.root / "worker.reparented", timeout=5.0)

        poller = select.poll()
        settle_deadline = time.monotonic() + 0.4
        while time.monotonic() < settle_deadline:
            if proc.poll() is not None or self.has_signalfd(proc.pid):
                break
            poller.poll(2)

        self.release_fifo(self.root / "worker.release")
        out, err = proc.communicate(timeout=5)
        elapsed = time.monotonic() - t0

        self.assertEqual(proc.returncode, -signal.SIGTERM, out + err)
        wait_file(self.root / "worker.flushed", timeout=2.0)
        with self.assertRaises(ProcessLookupError):
            os.kill(worker_pid, 0)

        log_path = self.prefix / ".eb-local" / "logs" / "easybuild-late.log"
        log_text = log_path.read_text(encoding="utf-8")
        self.assertNotIn(SECRET_VAL, log_text)
        self.assertIn("flushing <secret LICENCE_KEY removed by eb-local>", log_text)
        self.assertLess(elapsed, 0.42, f"expected wake on SIGCHLD before 500 ms deadline, took {elapsed:.3f}s")

    def test_sig_ign_straggler_is_killed_and_reaped_at_deadline(self):
        strag_bin = self.root / "strag-bin"
        strag_bin.mkdir()
        for tool in ("eb", "sbatch", "rtrash"):
            wrapper = strag_bin / tool
            wrapper.write_text(
                f'#!/bin/bash\nexport TREE_TAG={tool}\nexec python3 "$CONTROL_ROOT/straggler-tree.py" "$@"\n',
                encoding="utf-8",
            )
            wrapper.chmod(0o755)

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
            ("build", "eb", ["recipe.eb"], dict(self.env, BASH_ENV=str(self.no_eb_fn))),
            (
                "eb",
                "eb",
                ["eb", "zlib.eb"],
                dict(
                    self.env,
                    SLURM_JOB_ID="",
                    EESSI_CVMFS_REPO=str(self.root / "repo"),
                    EESSI_USER_INSTALL=str(self.root / "user-eessi"),
                ),
            ),
            ("submit", "sbatch", ["submit", "recipe.eb"], dict(self.env, SLURM_JOB_ID="", EB_LOCAL_CONFIG=str(submit_site))),
            ("clean", "rtrash", ["clean", "--no-logs", "--sources"], dict(self.env, SLURM_JOB_ID="")),
        ]

        for label, tag, args, case_env in cases:
            with self.subTest(command=label):
                for suffix in ("leader.pid", "straggler.pid"):
                    p = self.root / f"{tag}.{suffix}"
                    if p.exists():
                        p.unlink()
                argv, env = binary.command(self.script, args, case_env)
                env["PATH"] = f"{strag_bin}:{env['PATH']}"
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
                leader_pid = int(wait_file(self.root / f"{tag}.leader.pid"))
                straggler_pid = int(wait_file(self.root / f"{tag}.straggler.pid"))
                self.addCleanup(self.kill_if_alive, straggler_pid)
                self.addCleanup(self.kill_if_alive, leader_pid)

                os.kill(proc.pid, signal.SIGTERM)
                rc = proc.wait(timeout=3)
                alive = True
                try:
                    os.kill(straggler_pid, 0)
                except ProcessLookupError:
                    alive = False
                if alive:
                    self.kill_if_alive(straggler_pid)
                out, err = proc.communicate(timeout=2)
                self.assertEqual(rc, -signal.SIGTERM, out + err)
                self.assertFalse(alive, f"{label} left SIG_IGN straggler {straggler_pid} alive")


if __name__ == "__main__":
    unittest.main()
