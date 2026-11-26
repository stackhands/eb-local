#!/usr/bin/env python3
"""Bounded straggler waiting and reaping on `SIGCHLD` in `Guard.run`."""

import ctypes
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
PR_SET_CHILD_SUBREAPER = 36
PR_GET_CHILD_SUBREAPER = 37

LATE_WRITER = r'''
import os, select, signal

root = os.environ["CONTROL_ROOT"]
sync = "__SYNC__"
log = os.path.join(os.environ["EASYBUILD_TMP_LOGDIR"], "easybuild-late.log")
with open(log, "w", encoding="utf-8") as fh:
    fh.write("started\n")

def block(fd, events):
    poller = select.poll()
    poller.register(fd, events)
    while True:
        try:
            got = poller.poll()
        except InterruptedError:
            continue
        if got:
            return got[0][1]

def write_fifo(name, text):
    fd = os.open(os.path.join(sync, name), os.O_WRONLY)
    try:
        os.write(fd, text.encode())
    finally:
        os.close(fd)

def read_byte(name):
    fd = os.open(os.path.join(sync, name), os.O_RDONLY)
    try:
        while True:
            try:
                got = os.read(fd, 1)
            except InterruptedError:
                continue
            if got:
                return
    finally:
        os.close(fd)

# The worker opens a pidfd on the leader, then writes this pipe. The leader
# exits only after that write, so the pidfd is opened while the leader is alive.
armed_r, armed_w = os.pipe()
worker = os.fork()
if worker == 0:
    os.close(armed_r)
    sig_r, sig_w = os.pipe()
    os.set_blocking(sig_w, False)
    def on_sig(_sig, _frame):
        try:
            os.write(sig_w, b"1")
        except OSError:
            pass
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, on_sig)
    write_fifo("worker.ready", "%d\n" % os.getpid())
    block(sig_r, select.POLLIN)
    os.close(sig_r)
    os.close(sig_w)
    leader = os.getppid()
    pfd = os.pidfd_open(leader)
    os.write(armed_w, b"1")
    os.close(armed_w)
    block(pfd, select.POLLIN)
    os.close(pfd)
    # Readable only after the leader's exit, which reparents this worker first.
    write_fifo("worker.reparented", "%d\n" % os.getppid())
    read_byte("worker.release")
    with open(log, "a", encoding="utf-8") as fh:
        fh.write("flushing " + os.environ["LICENCE_KEY"] + "\n")
    write_fifo("worker.flushed", "1\n")
    os._exit(0)

os.close(armed_w)
sig_r, sig_w = os.pipe()
os.set_blocking(sig_w, False)
def on_leader(_sig, _frame):
    try:
        os.write(sig_w, b"1")
    except OSError:
        pass
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, on_leader)
write_fifo("leader.ready", "%d\n" % os.getpid())
block(sig_r, select.POLLIN)
os.close(sig_r)
os.close(sig_w)
while True:
    try:
        got = os.read(armed_r, 1)
    except InterruptedError:
        continue
    if got:
        break
os.close(armed_r)
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


@unittest.skipUnless(binary.ZIG, "straggler reaping belongs to the Zig binary")
class ChildPgroupReapCli(StorageFixture):
    def setUp(self):
        super().setUp()
        for name in ("LD_LIBRARY_PATH", "LD_PRELOAD", "LD_AUDIT"):
            self.env.pop(name, None)
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

    def hold_subreaper(self):
        """Orphaned grandchildren reparent here, so a missed reap stays visible."""
        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
        libc.prctl.restype = ctypes.c_int
        previous = ctypes.c_int(0)
        if libc.prctl(PR_GET_CHILD_SUBREAPER, ctypes.addressof(previous), 0, 0, 0) != 0:
            self.fail(f"cannot read PR_GET_CHILD_SUBREAPER ({ctypes.get_errno()})")
        if previous.value != 0:
            return
        if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
            self.fail(f"cannot set PR_SET_CHILD_SUBREAPER ({ctypes.get_errno()})")
        self.addCleanup(lambda: libc.prctl(PR_SET_CHILD_SUBREAPER, 0, 0, 0, 0))

    def open_fifo(self, directory: Path, name: str) -> int:
        path = directory / name
        os.mkfifo(path)
        fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, fd)
        return fd

    def read_line(self, fd: int, timeout: float = 10.0) -> str:
        """Read one line from a fifo. The wait is the writer's rendezvous."""
        poller = select.poll()
        poller.register(fd, select.POLLIN)
        deadline = time.monotonic() + timeout
        data = b""
        while b"\n" not in data:
            rem = deadline - time.monotonic()
            if rem <= 0:
                raise AssertionError(f"timed out reading a sync fifo: {data!r}")
            try:
                ready = poller.poll(max(1, int(rem * 1000)))
            except InterruptedError:
                continue
            if not ready:
                raise AssertionError(f"timed out reading a sync fifo: {data!r}")
            try:
                chunk = os.read(fd, 64)
            except BlockingIOError:
                continue
            if chunk:
                data += chunk
        return data.split(b"\n", 1)[0].decode()

    def test_cooperative_descendant_wakes_on_sigchld_before_secret_redaction(self):
        self.hold_subreaper()
        sync = self.root / f"reap-{os.getpid()}"
        sync.mkdir()
        fds = {
            name: self.open_fifo(sync, name)
            for name in ("leader.ready", "worker.ready", "worker.reparented", "worker.release", "worker.flushed")
        }
        (self.root / "late-writer.py").write_text(
            LATE_WRITER.replace("__SYNC__", str(sync)), encoding="utf-8")

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
        leader_pid = int(self.read_line(fds["leader.ready"]))
        worker_pid = int(self.read_line(fds["worker.ready"]))
        self.addCleanup(self.kill_if_alive, worker_pid)
        self.addCleanup(self.kill_if_alive, leader_pid)

        os.kill(proc.pid, signal.SIGTERM)
        ppid = int(self.read_line(fds["worker.reparented"]))
        self.assertEqual(ppid, proc.pid)
        self.assertNotEqual(ppid, leader_pid)
        self.assertNotEqual(ppid, 1)
        self.assertIsNone(proc.poll())
        try:
            os.kill(worker_pid, 0)
        except ProcessLookupError:
            self.fail("worker exited before it was released")

        os.write(fds["worker.release"], b"1")
        self.assertEqual(self.read_line(fds["worker.flushed"]), "1")
        out, err = proc.communicate(timeout=5)

        self.assertEqual(proc.returncode, -signal.SIGTERM, out + err)
        with self.assertRaises(ProcessLookupError):
            os.kill(worker_pid, 0)

        log_path = self.prefix / ".eb-local" / "logs" / "easybuild-late.log"
        log_text = log_path.read_text(encoding="utf-8")
        self.assertNotIn(SECRET_VAL, log_text)
        self.assertIn("flushing <secret LICENCE_KEY removed by eb-local>", log_text)

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
